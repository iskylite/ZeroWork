//! mockup-session-ended — 墓碑态设计稿复刻（docs/SPEC/html/mockup-session-ended.html）。
//!
//! 结构：tbar(40) + ebanner(38) + term(520, opacity .72) + sbar(28)。窗口 1280×626。
//! 要点：
//!  - 墓碑横幅：gray 系渐变底 + 底边线，左图标+标题+元信息+注，右三按钮（主=重新连接）；
//!  - 终端内容整体 opacity .72（SPEC §9：Ended=灰横幅 + 内容 .72）；
//!  - 状态栏灰点 + 墓碑说明。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 626 };
pub const title = "mockup-session-ended";

const tok = mock.tok;

/// gray.06 系（html rgba(100,116,139,x) = #64748B）。
const gray = ui.Color.rgb(0x64, 0x74, 0x8B);

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountEndedBanner(cx),
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

    // on 页签："⏹ K8s-Node01 (已结束) ✕"（⏹ 与文字与 ✕ 间 gap 6）。
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "⏹", .{ .font_size = 12, .color = tok.fg }));
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 (已结束)", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try tab.appendChild(cx.allocator, try ui.text(cx, "✕", .{ .font_size = 12, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, tab);

    try bar.appendChild(cx.allocator, try tabOff(cx, "RDS-PG ✕"));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡", false));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅", false));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨", true));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️", false));
    return bar;
}

fn tabOff(cx: *ui.Cx, name: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12,
        .color = tok.fg2,
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

// ── 墓碑横幅（38px） ────────────────────────────────────────────────

/// eb2 按钮：padding 4/13，圆角 7，字 11·500，白底 + rgba(0,0,0,.1) 边。
fn bannerButton(cx: *ui.Cx, label: []const u8, primary: bool) !*ui.Node {
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

fn mountEndedBanner(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 38 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 16, .right = 16, .top = 0, .bottom = 0 },
        .gradient = .{
            .from = tok.alpha(gray, 26), // rgba(100,116,139,.1)
            .to = tok.alpha(gray, 13), // rgba(100,116,139,.05)
            .direction = .horizontal,
        },
        .border = .{ .width = 1, .color = tok.alpha(gray, 64), .radius = 0, .side_widths = .{ -1, -1, 1, -1 } }, // rgba(100,116,139,.25)
        .z_index = 20,
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try ui.text(cx, "⏹", .{ .font_size = 13, .color = tok.fg }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "会话已结束", .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "远端 shell 正常退出 · exit 0 · 14:32:07 · 时长 2h 14m", .{
        .font_size = 12,
        .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "只读墓碑态 · 内容完整保留可回滚复制", .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try bannerButton(cx, "↻ 重新连接", true));
    try bar.appendChild(cx.allocator, try bannerButton(cx, "📜 回溯历史 @log", false));
    try bar.appendChild(cx.allocator, try bannerButton(cx, "✕ 关闭", false));
    return bar;
}

// ── 终端（520px，opacity .72） ─────────────────────────────────────

const td = tok.alpha(tok.fg, 140); // .td opacity .55

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 520 },
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .opacity = 0.72, // .dim2
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl rollout status deploy/backend-api", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "deployment \"backend-api\" successfully rolled out", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ exit", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "logout", .color = td }}, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Connection to 10.200.1.18 closed.", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    // 冻结说明行：Inter 11px。
    try term.appendChild(cx.allocator, try ui.text(cx, "—— 画面冻结于会话结束时刻 · 可滚动/复制/搜索 · ⌘⇧F 时间轴回放 · 关闭后历史仍可在「数据与日志」导出 ——", .{
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
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.fg3));
    try bar.appendChild(cx.allocator, try ui.text(cx, "已结束: K8s-Node01 · exit 0", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "只读墓碑态 · 重新连接将复用主机配置", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
