//! mockup-at-help — @help 内置指令速查卡复刻（docs/SPEC/html/mockup-at-help.html）。
//!
//! 结构：tbar(40) + term(560, 含居中 ov 压暗层) + sbar(28)。窗口 1100×628。
//! 卡片：580 宽居中，顶 y71 高 ~499；14 行速查 + 触发规则脚注。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1100, .height = 628 };
pub const title = "mockup-at-help";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_line5 = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40px；此稿仅一个 tab，无 ring 描边） ───────────────

fn mountTitleBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const tls = try ui.box(cx, .{
        .direction = .row,
        .gap = 8,
        .margin = .{ .top = 0, .right = 10, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    for ([_]ui.Color{ ui.Color.rgb(0xFF, 0x5F, 0x57), ui.Color.rgb(0xFF, 0xBD, 0x2E), ui.Color.rgb(0x28, 0xC8, 0x40) }) |c| {
        try tls.appendChild(cx.allocator, try mock.dot(cx, 12, c));
    }
    try bar.appendChild(cx.allocator, tls);

    // 单 tab：bg 底 / fg 字 / 500 / 阴影 0 1 3 rgba(0,0,0,.08)
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区（term 560px）+ ov 压暗层 + 居中卡片 ──────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    const td = tok.alpha(tok.fg, 140);
    // 行1：$ @help
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@help", .color = tok.acc, .weight = 600 },
    }, .{}));
    // 行2
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 内置指令速查", .color = td },
    }, .{}));

    // ov：铺满 term，rgba(236,255,244,.4)+blur(4)，居中卡
    // （inset 全 0 在 Zenit 中等价未设置，改用显式尺寸铺满）
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 1100 },
        .height = .{ .px = 560 },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(0xEC, 0xFF, 0xF4, 102),
        .glass = .{ .backdrop_blur = 4 },
        .z_index = 10,
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    try term.appendChild(cx.allocator, ov);
    return term;
}

// ── 速查卡（580 宽） ───────────────────────────────────────────────

const Cmd = struct { icon: []const u8, cmd: []const u8, ds: []const u8 };

const cmds = [_]Cmd{
    .{ .icon = "📤", .cmd = "@up [文件]", .ds = "上传（统一传输面板）" },
    .{ .icon = "📥", .cmd = "@dl <远程路径>", .ds = "下载（可选目录+重命名）" },
    .{ .icon = "✨", .cmd = "@ai [问题]", .ds = "AI 运维助手浮窗" },
    .{ .icon = "🖥️", .cmd = "@new", .ds = "同主机新会话·组内自动入组" },
    .{ .icon = "⧉", .cmd = "@dup", .ds = "镜像复制会话（含当前目录）" },
    .{ .icon = "👥", .cmd = "@grp <组名>", .ds = "加入/创建终端组" },
    .{ .icon = "📌", .cmd = "@pin", .ds = "组内置顶会话（AI/斜杠锚点）" },
    .{ .icon = "🔁", .cmd = "@sync on|off", .ds = "广播输入开关" },
    .{ .icon = "🕐", .cmd = "@ts on|off", .ds = "时间戳侧栏开关" },
    .{ .icon = "📜", .cmd = "@log", .ds = "历史回溯模式" },
    .{ .icon = "🧦", .cmd = "@socks on|off", .ds = "SOCKS5 动态转发开关" },
    .{ .icon = "🎨", .cmd = "@theme [名称]", .ds = "会话主题切换（default 恢复全局）" },
    .{ .icon = "❓", .cmd = "@help", .ds = "本速查浮层" },
    .{ .icon = "⌨️", .cmd = "@@", .ds = "转义字面 @" },
};

fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 580 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242), // rgba(248,255,251,.95)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 12 }, // rgba(19,69,246,.1)
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) }, // rgba(15,23,42,.14)
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 20,
        .overflow = .hidden,
    }, .{});

    // 头部（ch：padding 13 18，高 ~46，字 13·600 + 右注 10 fg3）
    const ch = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 46 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try ch.appendChild(cx.allocator, try ui.text(cx, "❓ 内置指令速查", .{
        .font_size = 13, .font_weight = 600, .color = tok.fg,
    }));
    try ch.appendChild(cx.allocator, try ui.spacer(cx));
    try ch.appendChild(cx.allocator, try ui.text(cx, "客户端本地执行 · 仅行首 @ 生效 · ESC 关闭", .{
        .font_size = 10, .font_weight = 400, .color = tok.fg3,
    }));
    try card.appendChild(cx.allocator, ch);

    // 14 行速查（容器 padding 5 0；行高 ~28.5）
    const rows = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
    }, .{});
    for (cmds) |c| {
        try rows.appendChild(cx.allocator, try cmdRow(cx, c));
    }
    try card.appendChild(cx.allocator, rows);

    // 脚注（cf：padding 9 18，两行 10px lh1.6）
    const cf = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 0,
        .padding = .{ .left = 18, .right = 18, .top = 9, .bottom = 9 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try cf.appendChild(cx.allocator, try ui.text(cx, "触发规则：提示符行缓冲区为空时键入 @ 生效；@ 前有空格或文本、全屏程序中均不触发", .{
        .font_size = 10, .color = tok.fg3, .line_height = 1.6,
    }));
    try cf.appendChild(cx.allocator, try ui.text(cx, "SFTP 面板自动跟随终端目录（OSC 7），无需切目录指令 · Tab 右键菜单内同样可用 @new/@dup", .{
        .font_size = 10, .color = tok.fg3, .line_height = 1.6,
    }));
    try card.appendChild(cx.allocator, cf);
    return card;
}

/// 速查行：ic(20) + cmd(150 mono 11·600 acc) + ds(11.5 fg2)。
fn cmdRow(cx: *ui.Cx, c: Cmd) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 11,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 20 },
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, c.icon, .{ .font_size = 12, .color = tok.fg }));
    try row.appendChild(cx.allocator, ic);
    const cmd_col = try ui.box(cx, .{
        .width = .{ .px = 150 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{});
    try cmd_col.appendChild(cx.allocator, try ui.text(cx, c.cmd, .{
        .font_size = 11, .font_weight = 600, .color = tok.acc, .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, cmd_col);
    try row.appendChild(cx.allocator, try ui.text(cx, c.ds, .{
        .font_size = 11.5, .color = tok.fg2,
    }));
    return row;
}

// ── 状态栏（sbar 28px） ─────────────────────────────────────────────

fn mountStatusBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .background = tok.stbg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.grn));
    try bar.appendChild(cx.allocator, try ui.text(cx, "内置指令 @help · 全部 14 条一览", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
