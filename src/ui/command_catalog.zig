const std = @import("std");

/// Shared by the local parser, command palette and @help card.
pub const Entry = struct {
    name: []const u8,
    usage: []const u8,
    description: []const u8,
    example: []const u8,
    icon: []const u8,
    palette_description: ?[]const u8 = null,
    requires_arguments: bool = false,

    pub fn paletteDescription(self: Entry) []const u8 {
        return self.palette_description orelse self.description;
    }
};

pub const operation_count = 13;

/// Order and wording follow mockup-at-help.png. @@ is an escape, not an action.
pub const entries = [_]Entry{
    .{ .name = "@up", .usage = "@up [文件]", .description = "上传（统一传输面板）", .example = "@up", .icon = "📤" },
    .{ .name = "@dl", .usage = "@dl <远程路径>", .description = "下载（可选目录+重命名）", .example = "@dl /var/log/app.log", .icon = "📥", .requires_arguments = true },
    .{ .name = "@ai", .usage = "@ai [问题]", .description = "打开 AI 助手，问题保留为草稿", .example = "@ai 连接为何失败", .icon = "✨" },
    .{ .name = "@new", .usage = "@new", .description = "同主机新会话·组内自动入组", .example = "@new", .icon = "🖥️" },
    .{ .name = "@dup", .usage = "@dup", .description = "镜像复制会话（含当前目录）", .example = "@dup", .icon = "⧉" },
    .{ .name = "@grp", .usage = "@grp <组名>", .description = "加入/创建终端组", .example = "@grp prod", .icon = "👥", .requires_arguments = true },
    .{ .name = "@pin", .usage = "@pin", .description = "组内置顶会话（AI/斜杠锚点）", .example = "@pin", .icon = "📌" },
    .{ .name = "@sync", .usage = "@sync on|off", .description = "广播输入开关", .example = "@sync on", .icon = "🔁", .requires_arguments = true },
    .{ .name = "@ts", .usage = "@ts [on|off]", .description = "切换时间戳侧栏（无参数自动开关）", .example = "@ts", .icon = "🕐" },
    .{ .name = "@log", .usage = "@log", .description = "历史回溯模式", .example = "@log", .icon = "📜" },
    .{ .name = "@socks", .usage = "@socks on|off", .description = "SOCKS5 动态转发开关", .example = "@socks on 1080", .icon = "🧦", .requires_arguments = true },
    .{ .name = "@theme", .usage = "@theme [名称]", .description = "全局主题选择（应用与全部终端）", .palette_description = "全局主题选择", .example = "@theme dark-pro", .icon = "🎨" },
    .{ .name = "@help", .usage = "@help", .description = "列出内置指令与用法", .example = "@help", .icon = "❓" },
    .{ .name = "@@", .usage = "@@", .description = "转义字面 @", .example = "@@", .icon = "⌨️" },
};

pub fn find(name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
    }
    return null;
}

test "catalog has thirteen operations plus the literal escape in the mockup order" {
    try std.testing.expectEqual(@as(usize, operation_count + 1), entries.len);
    try std.testing.expectEqualStrings("@up", entries[0].name);
    try std.testing.expectEqualStrings("@@", entries[operation_count].name);
    try std.testing.expect(find("@history") == null);
    try std.testing.expectEqualStrings("@log", find("@log").?.usage);
    try std.testing.expectEqualStrings("历史回溯模式", find("@log").?.description);
    try std.testing.expectEqualStrings("@new", find("@new").?.usage);
    for (entries, 0..) |entry, i| {
        for (entries[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }
    }
}
