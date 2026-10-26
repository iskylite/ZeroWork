//! mockup-reconnect — 断线重连横幅设计稿复刻（docs/SPEC/html/mockup-reconnect.html）。
//!
//! 结构：tbar(40) + rbanner(34) + term(560, opacity .55) + sbar(28)。窗口 1280×662。
//! 要点（SPEC §2）：
//!  - 重连横幅 34px：底红→琥珀 8%/6% 渐变，底边线 red.2；
//!  - 左：红呼吸点 8px + 标题 600 red + 元信息 + 倒计时 mono yel 600；
//!  - 右：主按钮「立即重连 ⌘R」+「保留现场并关闭」+ 指数退避注；
//!  - 倒计时环 12px 以双圆叠加模拟（外环 2px yel 边 + 内空）。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 662 };
pub const title = "mockup-reconnect";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountReconnectBanner(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（40px） ─────────────────────────────────────────────────

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

    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01 ✕", true));
    try bar.appendChild(cx.allocator, try tab(cx, "终端组: k8s-nodes ✕", false));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡", false));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅", false));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨", true));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️", false));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    }));
    return node;
}

fn globalIcon(cx: *ui.Cx, icon: []const u8, accent: bool) !*ui.Node {
    const icn = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 14,
        .color = if (accent) tok.acc else tok.fg2,
    }));
    return icn;
}

// ── 重连横幅（34px） ────────────────────────────────────────────────

/// 倒计时环 12px：外环（2px yel 边）+ 内空圆叠加。
fn countdownRing(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = 12 },
        .height = .{ .px = 12 },
        .border = .{ .width = 2, .color = tok.yel, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
}

/// rbtn：padding 4/13，圆角 7，字 11·500，白底 + rgba(0,0,0,.1) 边；pri=蓝底白字。
fn rbtn(cx: *ui.Cx, label: []const u8, primary: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 22 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 13, .right = 13, .top = 4, .bottom = 4 },
        .background = if (primary) tok.acc else tok.white,
        .border = .{ .width = 1, .color = if (primary) tok.acc else ui.Color.rgba(0, 0, 0, 26), .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11,
        .font_weight = 500,
        .color = if (primary) tok.white else tok.fg,
    }));
    return node;
}

fn mountReconnectBanner(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 16, .right = 16, .top = 0, .bottom = 0 },
        .gradient = .{
            .from = tok.alpha(tok.red, 20), // rgba(220,76,63,.08)
            .to = tok.alpha(tok.yel, 15), // rgba(212,154,12,.06)
            .direction = .horizontal,
        },
        .border = .{ .width = 1, .color = tok.alpha(tok.red, 51), .radius = 0, .side_widths = .{ -1, -1, 1, -1 } }, // rgba(220,76,63,.2)
        .z_index = 20,
        .flex_shrink = 0,
    }, .{});
    // 红色呼吸点 8px（动画取中态 100% 不透明）。
    try bar.appendChild(cx.allocator, try mock.dot(cx, 8, tok.red));
    try bar.appendChild(cx.allocator, try ui.text(cx, "连接已断开", .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.red,
    }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "Bastion-01 (118.31.22.10) 无响应 · 跳板链第 1 跳中断", .{
        .font_size = 12,
        .color = tok.fg2,
    }));
    // 倒计时：环 + mono yel 600 文本。
    try bar.appendChild(cx.allocator, try countdownRing(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "4s 后自动重连 (第 2/5 次)", .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.yel,
        .use_monospace_font = true,
    }));
    try bar.appendChild(cx.allocator, try rbtn(cx, "立即重连 ⌘R", true));
    try bar.appendChild(cx.allocator, try rbtn(cx, "保留现场并关闭", false));
    // 右注：margin-left auto（指数退避说明）。
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "指数退避 1→2→4→8→16s · VT 网格与滚动历史已保留 · 重连期间输入将缓存回放", .{
        .font_size = 10.5,
        .color = tok.fg2,
    }));
    return bar;
}

// ── 终端（560px，opacity .55） ─────────────────────────────────────

const td = tok.alpha(tok.fg, 140);

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .opacity = 0.55, // .dim2
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ tail -f /var/log/syslog", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:20:01 node01 CRON[8127]: (root) CMD (/usr/local/bin/health-check)", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:20:05 node01 kubelet[1024]: I1008 Container synced successfully", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:21:15 node01 sshd[9210]: Accepted publickey for ubuntu", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    // 冻结说明行：Inter 11px。
    try term.appendChild(cx.allocator, try ui.text(cx, "—— 画面冻结于断线前最后一刻 · 可用 @log 回溯完整历史 · 重连成功后追加 ── reconnected ── 标记行 ——", .{
        .font_size = 11,
        .color = td,
        .line_height = 1.5,
    }));
    return term;
}

// ── 状态栏（28px） ─────────────────────────────────────────────────

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
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.red));
    try bar.appendChild(cx.allocator, try ui.text(cx, "已断开: Bastion-01 → k8s-node01", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "自动重连进行中 (2/5)", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
