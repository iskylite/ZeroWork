//! Chinese action labels shared by pending steps, approvals and result records.
const std = @import("std");
pub fn title(name: []const u8) ?[]const u8 {
    var decoded: [64]u8 = undefined;
    const logical = @import("../ai/plugin_tools.zig").decodeName(&decoded, name) catch name;
    const labels = .{
        .{ "run_command", "执行命令" },
        .{ "read_terminal", "读取终端内容" },
        .{ "read_remote_file", "读取远程文件" },
        .{ "list_remote_files", "列出远程文件" },
        .{ "bmc_ikvm.screenshot", "读取远程画面" },
        .{ "bmc_ikvm.describe_frame", "读取画面状态" },
        .{ "bmc_ikvm.read_power_state", "读取电源状态" },
        .{ "bmc_ikvm.read_boot", "读取启动配置" },
        .{ "bmc_ikvm.pointer", "操作远程鼠标" },
        .{ "bmc_ikvm.keyboard", "操作远程键盘" },
        .{ "bmc_ikvm.operation_status", "查询输入发送状态" },
        .{ "image.read", "重新查看历史图片" },
        .{ "file.read_text", "读取文本文件" },
        .{ "file.write_text", "写入文本文件" },
        .{ "file.edit_text", "编辑文本文件" },
        .{ "host.local_list_files", "列出本地文件" },
        .{ "host.local_search_text", "搜索本地文件" },
        .{ "host.local_get_changes", "查看本地文件变更" },
        .{ "host.local_read_text", "读取文件" },
        .{ "host.local_write_text", "修改文件" },
        .{ "host.local_edit_text", "修改文件" },
        .{ "host.fetch_url", "读取网页内容" },
        .{ "host.skills", "读取本地技能" },
        .{ "host.mcp_catalog", "查询 MCP 工具" },
        .{ "host.mcp_request", "访问 MCP 资源" },
        .{ "host.mcp_result", "读取 MCP 结果" },
        .{ "host.mcp_call", "调用 MCP 工具" },
        .{ "host.get_current_context", "读取对话状态" },
        .{ "host.request_user_input", "询问用户" },
        .{ "host.run_builtin", "显示内置指令" },
        .{ "host.list_sessions", "列出会话" },
        .{ "host.list_hosts", "列出已保存主机" },
        .{ "host.get_host", "读取主机配置" },
        .{ "host.create_host", "保存新主机" },
        .{ "host.upload_file", "上传文件" },
        .{ "host.download_file", "下载文件" },
        .{ "host.get_transfer", "查询传输进度" },
        .{ "host.wait_transfer", "等待文件传输" },
        .{ "host.cancel_transfer", "取消文件传输" },
        .{ "host.get_session", "读取会话状态" },
        .{ "host.list_groups", "列出会话组" },
        .{ "host.get_group", "读取会话组状态" },
        .{ "host.list_group_members", "列出组成员" },
        .{ "host.read_terminal", "读取终端内容" },
        .{ "host.read_command_output", "读取命令输出" },
        .{ "host.search_terminal", "搜索终端内容" },
        .{ "host.list_terminal_commands", "列出命令执行记录" },
        .{ "host.create_group", "创建会话组" },
        .{ "host.open_session", "新建会话" },
        .{ "host.rename_group", "重命名会话组" },
        .{ "host.add_group_member", "将会话加入组" },
        .{ "host.remove_group_member", "将会话移出组" },
        .{ "host.close_session", "关闭会话" },
        .{ "host.disconnect_session", "断开会话" },
        .{ "host.reconnect_session", "重新连接会话" },
        .{ "host.set_session_retention", "设置会话保留策略" },
        .{ "host.wait_session_ready", "等待会话就绪" },
        .{ "host.run_command", "执行命令" },
        .{ "host.run_in_terminal", "在终端中执行命令" },
        .{ "host.attach_shell", "接入当前终端" },
        .{ "host.get_execution", "读取命令执行状态" },
        .{ "host.wait_execution", "等待命令执行更新" },
        .{ "host.send_execution_input", "向终端输入内容" },
        .{ "host.stop_execution", "停止命令执行" },
    };
    inline for (labels) |item| if (std.mem.eql(u8, logical, item[0])) return item[1];
    return null;
}

/// Display-only action names. Incomplete or unrecognized arguments retain the
/// tool's general action; raw arguments are never rewritten for dispatch/copy.
pub fn action(a: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
    var decoded: [64]u8 = undefined;
    const logical = @import("../ai/plugin_tools.zig").decodeName(&decoded, name) catch name;
    const fallback = title(name) orelse "工具调用";
    const pointer = std.mem.eql(u8, logical, "bmc_ikvm.pointer");
    const keyboard = std.mem.eql(u8, logical, "bmc_ikvm.keyboard");
    if (!pointer and !keyboard) return a.dupe(u8, fallback);
    const parsed = std.json.parseFromSlice(std.json.Value, a, arguments, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return a.dupe(u8, fallback);
    };
    defer parsed.deinit();
    const value = parsed.value;
    const kind = string(value, "action") orelse return a.dupe(u8, fallback);
    if (pointer) {
        const label = if (std.mem.eql(u8, kind, "move")) "移动远程鼠标" else if (std.mem.eql(u8, kind, "drag")) "在远程画面中拖拽" else if (std.mem.eql(u8, kind, "wheel")) "滚动远程画面" else if (std.mem.eql(u8, kind, "click")) click: {
            const button = if (value.object.contains("button")) string(value, "button") orelse break :click fallback else "left";
            const count: std.json.Value = value.object.get("count") orelse .{ .integer = 1 };
            if (count != .integer or (count.integer != 1 and count.integer != 2)) break :click fallback;
            if (std.mem.eql(u8, button, "left")) break :click if (count.integer == 2) "双击远程画面" else "单击远程画面";
            if (std.mem.eql(u8, button, "right")) break :click if (count.integer == 2) "右键双击远程画面" else "右键单击远程画面";
            if (std.mem.eql(u8, button, "middle")) break :click if (count.integer == 2) "中键双击远程画面" else "中键单击远程画面";
            break :click fallback;
        } else fallback;
        return a.dupe(u8, label);
    }
    if (std.mem.eql(u8, kind, "text")) return a.dupe(u8, "输入文本");
    if (std.mem.eql(u8, kind, "key")) {
        var key_buffer: [16]u8 = undefined;
        const key = keyName(&key_buffer, value.object.get("keysym") orelse .null) orelse return a.dupe(u8, "发送按键");
        return std.fmt.allocPrint(a, "发送按键 {s}", .{key});
    }
    if (std.mem.eql(u8, kind, "chord")) {
        const keys = value.object.get("keys") orelse return a.dupe(u8, "发送组合键");
        if (keys != .array or keys.array.items.len == 0 or keys.array.items.len > 8) return a.dupe(u8, "发送组合键");
        var buffer: [160]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        for (keys.array.items, 0..) |symbol, index| {
            var key_buffer: [16]u8 = undefined;
            const key = keyName(&key_buffer, symbol) orelse return a.dupe(u8, "发送组合键");
            try writer.print("{s}{s}", .{ if (index == 0) "" else " + ", key });
        }
        return std.fmt.allocPrint(a, "发送组合键 {s}", .{writer.buffered()});
    }
    return a.dupe(u8, fallback);
}

pub fn detail(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var decoded: [64]u8 = undefined;
    return std.fmt.allocPrint(a, "工具：{s}", .{@import("../ai/plugin_tools.zig").decodeName(&decoded, name) catch name});
}

fn string(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(field) orelse return null;
    return if (item == .string) item.string else null;
}

fn keyName(buffer: []u8, value: std.json.Value) ?[]const u8 {
    if (value != .integer) return null;
    return switch (value.integer) {
        0x20 => "Space",
        0x21...0x7e => std.fmt.bufPrint(buffer, "{c}", .{std.ascii.toUpper(@intCast(value.integer))}) catch null,
        0xff08 => "Backspace",
        0xff09 => "Tab",
        0xff0d => "Enter",
        0xff1b => "Esc",
        0xffff => "Delete",
        0xff50 => "Home",
        0xff51 => "Left",
        0xff52 => "Up",
        0xff53 => "Right",
        0xff54 => "Down",
        0xff55 => "Page Up",
        0xff56 => "Page Down",
        0xff57 => "End",
        0xff63 => "Insert",
        0xffbe...0xffd5 => std.fmt.bufPrint(buffer, "F{d}", .{value.integer - 0xffbe + 1}) catch null,
        0xffe1, 0xffe2 => "Shift",
        0xffe3, 0xffe4 => "Ctrl",
        0xffe9, 0xffea => "Alt",
        0xffeb, 0xffec => "Super",
        else => null,
    };
}

test "tool action labels distinguish mouse and keyboard parameters and tolerate incomplete input" {
    const a = std.testing.allocator;
    const cases = [_]struct { name: []const u8 = "bmc_ikvm.pointer", args: []const u8, expected: []const u8 }{
        .{ .args = "{\"action\":\"move\"}", .expected = "移动远程鼠标" },
        .{ .args = "{\"action\":\"click\"}", .expected = "单击远程画面" },
        .{ .args = "{\"action\":\"click\",\"count\":2}", .expected = "双击远程画面" },
        .{ .args = "{\"action\":\"click\",\"button\":\"right\"}", .expected = "右键单击远程画面" },
        .{ .args = "{\"action\":\"click\",\"button\":\"middle\"}", .expected = "中键单击远程画面" },
        .{ .args = "{\"action\":\"click\",\"button\":\"right\",\"count\":2}", .expected = "右键双击远程画面" },
        .{ .args = "{\"action\":\"click\",\"button\":\"middle\",\"count\":2}", .expected = "中键双击远程画面" },
        .{ .args = "{\"action\":\"drag\"}", .expected = "在远程画面中拖拽" },
        .{ .args = "{\"action\":\"wheel\"}", .expected = "滚动远程画面" },
        .{ .args = "{\"action\":\"click\",\"button\":false}", .expected = "操作远程鼠标" },
        .{ .args = "{\"action\":\"click\",\"count\":3}", .expected = "操作远程鼠标" },
        .{ .args = "{\"action\":\"unknown\"}", .expected = "操作远程鼠标" },
        .{ .args = "{\"action\":\"cli", .expected = "操作远程鼠标" },
        .{ .args = "[]", .expected = "操作远程鼠标" },
        .{ .args = "{\"action\":42}", .expected = "操作远程鼠标" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"text\",\"text\":\"private text\"}", .expected = "输入文本" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"key\",\"keysym\":65293}", .expected = "发送按键 Enter" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"key\",\"keysym\":65481}", .expected = "发送按键 F12" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"key\",\"keysym\":65507}", .expected = "发送按键 Ctrl" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"key\",\"keysym\":-1}", .expected = "发送按键" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"key\"}", .expected = "发送按键" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"chord\",\"keys\":[65507,99]}", .expected = "发送组合键 Ctrl + C" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"chord\",\"keys\":[65507,65513,65535]}", .expected = "发送组合键 Ctrl + Alt + Delete" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"chord\",\"keys\":[65507,999999]}", .expected = "发送组合键" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"chord\",\"keys\":[]}", .expected = "发送组合键" },
        .{ .name = "bmc_ikvm.keyboard", .args = "{\"action\":\"unknown\"}", .expected = "操作远程键盘" },
        .{ .name = "bmc_ikvm.screenshot", .args = "{}", .expected = "读取远程画面" },
        .{ .name = "bmc_ikvm.describe_frame", .args = "{}", .expected = "读取画面状态" },
    };
    for (cases) |case| {
        var encoded: [64]u8 = undefined;
        const wire = try @import("../ai/plugin_tools.zig").encodeName(&encoded, case.name);
        for ([_][]const u8{ case.name, wire }) |name| {
            const actual = try action(a, name, case.args);
            defer a.free(actual);
            try std.testing.expectEqualStrings(case.expected, actual);
        }
    }
    for (@import("../plugins/bmc_ikvm/tools.zig").definitions) |definition| try std.testing.expect(title(definition.id) != null);
}
