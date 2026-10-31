//! Chinese action labels shared by pending steps, approvals and result records.
const std = @import("std");
pub fn title(name: []const u8) ?[]const u8 {
    var decoded: [64]u8 = undefined;
    const logical = @import("../ai/plugin_tools.zig").decodeName(&decoded, name) catch name;
    const labels = .{
        .{ "host.fetch_url", "获取网页" },
        .{ "host.get_current_context", "读取对话状态" },
        .{ "host.list_sessions", "列出会话" },
        .{ "host.list_hosts", "列出已存主机" },
        .{ "host.get_host", "读取主机配置" },
        .{ "host.create_host", "保存新主机" },
        .{ "host.get_session", "读取会话状态" },
        .{ "host.list_groups", "列出会话组" },
        .{ "host.get_group", "读取会话组状态" },
        .{ "host.list_group_members", "列出组成员" },
        .{ "host.read_terminal", "读取终端片段" },
        .{ "host.search_terminal", "搜索终端内容" },
        .{ "host.list_terminal_commands", "列出执行记录" },
        .{ "host.create_group", "创建会话组" },
        .{ "host.open_session", "新建会话" },
        .{ "host.rename_group", "重命名会话组" },
        .{ "host.add_group_member", "加入会话组" },
        .{ "host.remove_group_member", "移出会话组" },
        .{ "host.close_session", "关闭会话" },
        .{ "host.disconnect_session", "断开会话" },
        .{ "host.reconnect_session", "重连会话" },
        .{ "host.set_session_retention", "设置保留策略" },
        .{ "host.wait_session_ready", "等待会话就绪" },
        .{ "host.run_command", "执行命令" },
        .{ "host.run_in_terminal", "执行命令" },
        .{ "host.get_execution", "读取执行状态" },
        .{ "host.wait_execution", "等待执行更新" },
        .{ "host.send_execution_input", "提交终端输入" },
        .{ "host.stop_execution", "停止执行" },
    };
    inline for (labels) |item| if (std.mem.eql(u8, logical, item[0])) return item[1];
    return null;
}
