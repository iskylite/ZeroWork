//! mockup-at-dup — @dup 复制会话设计稿复刻（docs/SPEC/html/mockup-at-dup.html）。
//!
//! 结构：tbar(40) + term(560, 顶端 150 处挂 400 宽提示卡) + sbar(28)。窗口 1100×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1100, .height = 628 };
pub const title = "mockup-at-dup";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_line7 = ui.Color.rgba(15, 23, 42, 18); // rgba(15,23,42,.07) 卡边框

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏 ─────────────────────────────────────────────────────────

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

    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01", true));
    try bar.appendChild(cx.allocator, try tab(cx, "⧉ K8s-Node01 ⧉", false));

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️"));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = if (on) .{ .width = 1, .color = tok.bd, .radius = 7 } else .{ .width = 0, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    }));
    try node.appendChild(cx.allocator, try ui.text(cx, "✕", .{ .font_size = 9, .color = tok.fg3 }));
    return node;
}

fn globalIcon(cx: *ui.Cx, icon: []const u8) !*ui.Node {
    const icn = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 14,
        .color = if (std.mem.eql(u8, icon, "✨")) tok.acc else tok.fg2,
    }));
    return icn;
}

// ── 终端区 + 提示卡（ov 透明，顶端 150） ────────────────────────────

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
    // 行1：$ @dup（cwd 为 /opt/deploy/releases）
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "/opt/deploy/releases", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@dup", .color = tok.acc, .weight = 600 },
    }, .{}));
    // 行2-5
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 复制当前会话（镜像模式）…", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 新会话就绪 · 已自动 cd /opt/deploy/releases（OSC 7 当前目录镜像）", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "          差异: @new = 全新会话（走主机启动命令）· @dup = 镜像当前状态（同 cwd）", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "          两者均在组内时自动入组；均复用链路凭据不二次认证", .color = td },
    }, .{}));
    // 行6：光标行
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "/opt/deploy/releases", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));

    // 提示卡（ov 透明、align flex-start、padding-top 150、水平居中）
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 1100 },
        .height = .{ .px = 560 },
        .direction = .column,
        .align_items = .center,
        .z_index = 10,
    }, .{});
    const card = try ui.box(cx, .{
        .width = .{ .px = 400 },
        .direction = .column,
        .margin = .{ .top = 150, .right = 0, .bottom = 0, .left = 0 },
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242),
        .border = .{ .width = 1, .color = c_line7, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) }, // 0 16px 44px rgba(15,23,42,.14)
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 20,
        .padding = .{ .left = 18, .right = 18, .top = 14, .bottom = 14 },
    }, .{});
    // 标题
    const head = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 8, .left = 0 },
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "⧉ 会话已复制", .{
        .font_size = 12.5, .font_weight = 600, .color = tok.fg,
    }));
    try card.appendChild(cx.allocator, head);
    // 正文 3 行（11px fg2 lh 1.7）
    try card.appendChild(cx.allocator, try ui.text(cx, "新标签 K8s-Node01 ⧉ 已打开", .{
        .font_size = 11, .color = tok.fg2, .line_height = 1.7, .font_weight = 600,
    }));
    const l2 = try ui.box(cx, .{ .direction = .row, .flex_wrap = .wrap }, .{});
    try l2.appendChild(cx.allocator, try ui.text(cx, "镜像内容：主机配置 · 当前目录 ", .{
        .font_size = 11, .color = tok.fg2, .line_height = 1.7,
    }));
    try l2.appendChild(cx.allocator, try ui.text(cx, "/opt/deploy/releases", .{
        .font_size = 10, .color = tok.acc, .use_monospace_font = true,
    }));
    try card.appendChild(cx.allocator, l2);
    try card.appendChild(cx.allocator, try ui.text(cx, "未镜像：运行中的前台进程（各自独立 shell）", .{
        .font_size = 11, .color = tok.fg2, .line_height = 1.7,
    }));
    try ov.appendChild(cx.allocator, card);
    try term.appendChild(cx.allocator, ov);
    return term;
}

// ── 状态栏 ─────────────────────────────────────────────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "@dup · 镜像当前会话（同主机+同目录）· 与 @new 互补", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
