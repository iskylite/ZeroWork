//! A local file change is a presentation of a host operation receipt. Its
//! stored target never follows the currently selected workspace.
const std = @import("std");
const ui = @import("ui");
const changes = @import("../host/local_file_changes.zig");
const commit = @import("../host/local_file_commit.zig");
const facts = @import("../ai/tool_results.zig");
const S = @import("ai_tool_results_styles.zig");
const Step = @import("ai_step_view.zig");

pub const Receipt = struct {
    target: []const u8,
    status: commit.Status,
    committed: bool,
    verified: bool,
    conflict: bool,
    coverage: ?[]const u8 = null,
    created_parent_count: u8 = 0,
    created_parents: []const []const u8 = &.{},
    error_code: ?[]const u8 = null,
    recovery_ref: ?[]const u8 = null,
    original_retained: bool = false,
    diff: ?changes.Diff = null,
    diff_expired: bool = false,

    fn valid(self: Receipt) bool {
        if (!std.fs.path.isAbsolute(self.target)) return false;
        return switch (self.status) {
            .verified => self.committed and self.verified and !self.conflict,
            .committed_unverified => self.committed and !self.verified,
            .unknown => true,
            .partial => !self.committed and !self.verified and self.created_parent_count > 0,
            .rejected => !self.committed and !self.verified and !self.conflict,
        };
    }
    fn statusLabel(self: Receipt) []const u8 {
        if (self.committed and self.conflict) return "文件已写入，检测到并发修改";
        return switch (self.status) {
            .verified => "",
            .committed_unverified => "文件已写入，结果待核实",
            .unknown => if (self.committed) "文件已写入，记录待核实" else "写入结果待核实",
            .partial => "已创建目录，文件未写入",
            .rejected => "未写入",
        };
    }
};

/// Render only typed results of the built-in write tools. Ordinary tool text
/// (including other extensions' data) still uses the generic step card.
pub fn mountRecord(cx: *ui.Cx, scope: *ui.Scope, record: *facts.Record, on_toggle: ?ui.Handler(void)) !?*ui.Node {
    var name_buffer: [64]u8 = undefined;
    const logical = @import("../ai/plugin_tools.zig").decodeName(&name_buffer, record.name) catch record.name;
    const from_host = std.mem.eql(u8, logical, "host.local_write_text") or std.mem.eql(u8, logical, "host.local_edit_text");
    const from_terminal = std.mem.eql(u8, logical, "file.write_text") or std.mem.eql(u8, logical, "file.edit_text");
    if (!from_host and !from_terminal) return null;
    const content = if (from_host) host: {
        const fact = record.host orelse return null;
        break :host fact.content;
    } else if (record.targets.len == 1) record.targets[0].result.stdout else return null;
    if (content.len > 48 * 1024) return null;
    const parsed = std.json.parseFromSlice(Receipt, cx.allocator, content, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    defer parsed.deinit();
    const receipt = parsed.value;
    if (!receipt.valid()) return null;
    if (from_terminal and !std.mem.eql(u8, receipt.coverage orelse "", "managed_local_file_tools")) return null;
    if (receipt.status == .verified and (if (from_host) record.host.?.status != .succeeded else record.targets[0].result.status != .succeeded)) return null;
    return try mount(cx, scope, parsed.value, .{
        .tool_name = record.name,
        .test_id = record.testId(),
        .expanded = &record.expanded,
        .elapsed_ms = if (receipt.status == .rejected) null else record.total_elapsed_ms,
        .on_toggle = on_toggle,
    });
}

pub const Options = struct {
    tool_name: []const u8 = "host.local_edit_text",
    test_id: []const u8 = "ai.workspace.file_change",
    expanded: *bool,
    elapsed_ms: ?u64 = null,
    on_toggle: ?ui.Handler(void) = null,
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, receipt: Receipt, options: Options) !*ui.Node {
    if (!receipt.valid()) return error.InvalidChangeReceipt;
    const body = try ui.box(cx, S.changeBody(), .{});
    _ = try detail(cx, body, receipt.target, S.changePath(cx.tokens), "ai.workspace.change.path");
    const status = receipt.statusLabel();
    if (status.len != 0) {
        const node = try detail(cx, body, status, S.text(cx.tokens), "ai.workspace.change.status");
        node.setTextColor(@import("app_theme.zig").current().warn);
    }
    if (receipt.error_code) |code| {
        const reason: ?[]const u8 = if (std.mem.eql(u8, code, "WorkspaceChanged")) "工作区已变更" else if (std.mem.eql(u8, code, "SourceChanged")) "文件已变更，请重新读取" else if (std.mem.eql(u8, code, "VersionFormatUnsupported")) "版本格式已更新，请重新读取" else if (std.mem.eql(u8, code, "ToolApprovalRejected")) "审批已拒绝" else null;
        if (reason) |text| _ = try detail(cx, body, text, S.text(cx.tokens), "ai.workspace.change.reason");
    }
    for (receipt.created_parents[0..@min(receipt.created_parents.len, 16)]) |directory| {
        _ = try detail(cx, body, directory, S.changePath(cx.tokens), "ai.workspace.change.created_parent");
    }
    if (receipt.recovery_ref) |reference| {
        const message = try std.fmt.allocPrint(cx.allocator, "{s}恢复引用 {s}", .{ if (receipt.original_retained) "原内容已保留 · " else "", reference });
        defer cx.allocator.free(message);
        _ = try detail(cx, body, message, S.text(cx.tokens), "ai.workspace.change.recovery");
    }
    var counts: ?[]u8 = null;
    defer if (counts) |label| cx.allocator.free(label);
    if (receipt.diff_expired) {
        _ = try detail(cx, body, "差异内容已过期", S.text(cx.tokens), "ai.workspace.change.unavailable");
    } else if (receipt.diff) |diff| {
        if (receipt.status == .verified) {
            if (diff.added) |added| if (diff.removed) |removed| {
                counts = try std.fmt.allocPrint(cx.allocator, "+{d} −{d}", .{ added, removed });
            };
        }
        for (diff.lines[0..@min(diff.lines.len, 96)]) |line| try mountLine(cx, body, line);
        if (diff.truncated or diff.lines.len > 96) {
            _ = try detail(cx, body, "部分差异未显示", S.text(cx.tokens), "ai.workspace.change.truncated");
        }
    } else if (receipt.committed) {
        _ = try detail(cx, body, "差异内容暂不可用", S.text(cx.tokens), "ai.workspace.change.unavailable");
    }
    const name = std.fs.path.basename(receipt.target);
    const suffix = if (status.len > 0) status else counts orelse if (receipt.diff_expired) "差异已过期" else "";
    const summary = if (suffix.len > 0) try std.fmt.allocPrint(cx.allocator, "{s} · {s}", .{ name, suffix }) else try cx.allocator.dupe(u8, name);
    defer cx.allocator.free(summary);
    return Step.mount(cx, scope, .{
        .title = "修改文件",
        .tool_name = options.tool_name,
        .projection = summary,
        .projection_is_status = true,
        .detail = "",
        .detail_content = body,
        .copy_detail = false,
        .phase = switch (receipt.status) {
            .verified => .succeeded,
            .partial => .failed,
            .rejected => .rejected,
            .committed_unverified, .unknown => .failed,
        },
        .elapsed_ms = options.elapsed_ms orelse 0,
        .show_elapsed = options.elapsed_ms != null,
        .expanded = options.expanded,
        .test_id = options.test_id,
        .on_toggle = options.on_toggle,
    });
}

fn detail(cx: *ui.Cx, parent: *ui.Node, text: []const u8, style: ui.TextStyle, id: []const u8) !*ui.Node {
    const node = try ui.text(cx, text, style);
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
    return node;
}

fn mountLine(cx: *ui.Cx, parent: *ui.Node, line: changes.Line) !void {
    const row = try ui.box(cx, S.changeLine(line.kind), .{});
    row.meta.ownership.meta.test_id = if (line.kind == .add) "ai.workspace.change.add" else "ai.workspace.change.remove";
    var number: [24]u8 = undefined;
    const line_number = try ui.text(cx, try std.fmt.bufPrint(&number, "{d}", .{line.number}), S.changeNumber(cx.tokens));
    line_number.setStyleInline(cx.allocator, .{ .width = .{ .px = 30 }, .flex_shrink = 0 });
    try row.appendChild(cx.allocator, line_number);
    const code_style = S.changeCode(cx.tokens, line.kind);
    const marker = try ui.text(cx, if (line.kind == .add) "+" else "−", code_style);
    marker.setStyleInline(cx.allocator, .{ .width = .{ .px = 8 }, .flex_shrink = 0 });
    try row.appendChild(cx.allocator, marker);
    const text = try ui.text(cx, std.mem.trimEnd(u8, line.text, "\r\n"), code_style);
    text.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    try row.appendChild(cx.allocator, text);
    try parent.appendChild(cx.allocator, row);
}
