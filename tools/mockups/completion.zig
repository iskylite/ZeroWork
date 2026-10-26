//! mockup-completion — 补全设计稿复刻（docs/SPEC/html/mockup-completion.html）。
//!
//! 结构：tbar(40) + term(600) + sbar(28)。窗口 1280×668。要点（SPEC §8）：
//!  - ghost-text：fg3 60% 内联灰 + ⇥ 注释；
//!  - ⌘; 补全菜单：宽 520（html 实值）、头 tag + 候选行（来源徽标 历史=绿/内置=灰/路径缓存=青）
//!    + 匹配片段 accent 高亮 + freq 注 + 底部快捷键行；
//!  - 输入行高亮 + accent 块光标。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 668 };
pub const title = "mockup-completion";

const tok = mock.tok;

const td = tok.alpha(tok.fg, 140); // .td opacity .55
const ghost = tok.alpha(tok.fg3, 140); // #94A3B8 · opacity .55

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
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

// ── 终端（600px） ───────────────────────────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    // 行1：systemctl status nginx
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ systemctl status nginx", .color = tok.fg },
    }, .{}));
    // 行2-3：nginx 状态输出
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "● nginx.service - A high performance web server", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "   Active: ", .color = td },
        .{ .text = "active (running)", .color = tok.grn },
        .{ .text = " since Wed 2026-10-07", .color = td },
    }, .{}));
    // 空行
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    // 行5：kubectl rollout restart + ghost-text + 注释
    const ghost_line = try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl rollout restart deploy/", .color = tok.fg },
        .{ .text = "backend-api -n prod", .color = ghost },
    }, .{});
    try ghost_line.appendChild(cx.allocator, try ui.text(cx, "  ⇥ ghost-text（frecency 排序：历史频率 × 时间衰减）→ 接受 / Esc 忽略", .{
        .font_size = 10,
        .color = tok.fg3,
    }));
    try term.appendChild(cx.allocator, ghost_line);
    // 空行
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    // 行7：输入行 + acc 块光标 + 注释（块光标由 common.termLine cursor 提供 fg 底；
    // html 此处为 acc 底光标 → 本行单独自绘）。
    const input_row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 3, .right = 0, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 15), // rgba(19,69,246,.06)
        .inset_shadows = ui.InsetShadowList.of(&.{.{ .color = tok.acc, .blur = 0, .offset_x = 3, .offset_y = 0 }}),
        .border = .{ .width = 0, .color = tok.acc, .radius = 3 },
        .flex_shrink = 0,
    }, .{});
    try input_row.appendChild(cx.allocator, try ui.text(cx, "ubuntu", .{
        .font_size = 13, .color = tok.cyn, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "@k8s-node01:", .{
        .font_size = 13, .color = tok.fg, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "~", .{
        .font_size = 13, .color = tok.acc2, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "$ kubectl ", .{
        .font_size = 13, .color = tok.fg, .use_monospace_font = true, .line_height = 1.5,
    }));
    // acc 块光标 8×16。
    try input_row.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 8 },
        .height = .{ .px = 16 },
        .background = tok.acc,
        .flex_shrink = 0,
    }, .{}));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "  ⌘; 全量补全菜单", .{
        .font_size = 10,
        .color = tok.fg3,
    }));
    try term.appendChild(cx.allocator, input_row);

    // 补全菜单（html left 150 top 132 width 520）。
    try term.appendChild(cx.allocator, try mountCompletionMenu(cx));
    return term;
}

// ── 补全菜单 ───────────────────────────────────────────────────────

const Src = enum { history, builtin, path };

fn srcBadge(cx: *ui.Cx, src: Src) !*ui.Node {
    const cfg: struct { bg: ui.Color, fg: ui.Color, label: []const u8 } = switch (src) {
        // h: rgba(16,185,129,.1) #059669
        .history => .{ .bg = tok.alpha(ui.Color.rgb(0x10, 0xB9, 0x81), 26), .fg = ui.Color.rgb(0x05, 0x96, 0x69), .label = "历史" },
        // p: rgba(6,182,212,.1) #0E7490
        .path => .{ .bg = tok.alpha(tok.cyn, 26), .fg = ui.Color.rgb(0x0E, 0x74, 0x90), .label = "路径缓存" },
        // s: #F1F5F9 #64748B
        .builtin => .{ .bg = ui.Color.rgb(0xF1, 0xF5, 0xF9), .fg = ui.Color.rgb(0x64, 0x74, 0x8B), .label = "内置" },
    };
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 2, .bottom = 2 },
        .background = cfg.bg,
        .border = .{ .width = 0, .color = cfg.bg, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, cfg.label, .{
        .font_size = 9,
        .font_weight = 600,
        .color = cfg.fg,
    }));
    return node;
}

/// 候选行：cmd(fg) + 高亮片段(acc 700) + 徽标 + freq。
fn candidate(
    cx: *ui.Cx,
    cmd: []const u8,
    matched: []const u8,
    src: Src,
    freq: []const u8,
    selected: bool,
) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 29 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .background = if (selected) tok.alpha(tok.acc, 18) else ui.Color.TRANSPARENT, // rgba(19,69,246,.07)
        .flex_shrink = 0,
    }, .{});
    const cc2 = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
    }, .{});
    try cc2.appendChild(cx.allocator, try ui.text(cx, cmd, .{
        .font_size = 12,
        .color = tok.fg,
        .use_monospace_font = true,
    }));
    try cc2.appendChild(cx.allocator, try ui.text(cx, matched, .{
        .font_size = 12,
        .font_weight = 700,
        .color = tok.acc,
        .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, cc2);
    try row.appendChild(cx.allocator, try srcBadge(cx, src));
    if (freq.len > 0) {
        try row.appendChild(cx.allocator, try ui.text(cx, freq, .{
            .font_size = 9.5,
            .color = tok.fg3,
            .use_monospace_font = true,
        }));
    }
    return row;
}

fn kbd(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 5, .right = 5, .top = 1, .bottom = 1 },
        .background = tok.btn_sec_bg,
        .border = .{ .width = 1, .color = tok.setbd, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10,
        .color = tok.fg2,
        .use_monospace_font = true,
    }));
    return node;
}

fn mountCompletionMenu(cx: *ui.Cx) !*ui.Node {
    const menu = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 132 }, .left = .{ .px = 150 } },
        .width = .{ .px = 520 },
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242), // rgba(248,255,251,.95)
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 18), .radius = 12 }, // rgba(15,23,42,.07)
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) }, // rgba(15,23,42,.14)
        .glass = .{ .backdrop_blur = 24 },
        .overflow = .hidden,
        .z_index = 20,
        .flex_shrink = 0,
    }, .{});

    // 头部：tag + 说明。
    const header = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 13), .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const tag = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 1, .bottom = 1 },
        .background = tok.alpha(tok.acc, 20), // rgba(19,69,246,.08)
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try tag.appendChild(cx.allocator, try ui.text(cx, "kubectl", .{
        .font_size = 10.5,
        .font_weight = 600,
        .color = tok.acc,
        .use_monospace_font = true,
    }));
    try header.appendChild(cx.allocator, tag);
    try header.appendChild(cx.allocator, try ui.text(cx, "补全 · App 级本地预测 · 不发送远端 · 可在设置关闭", .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    try menu.appendChild(cx.allocator, header);

    // 候选 ×6。
    try menu.appendChild(cx.allocator, try candidate(cx, "kubectl ", "get pods -n prod-app", .history, "×23 · 2m前", true));
    try menu.appendChild(cx.allocator, try candidate(cx, "kubectl ", "get deploy -n prod", .history, "×17 · 8m前", false));
    try menu.appendChild(cx.allocator, try candidate(cx, "kubectl ", "logs -f backend-api --tail=100", .history, "×9 · 1h前", false));
    try menu.appendChild(cx.allocator, try candidate(cx, "kubectl ", "get nodes -o wide", .builtin, "", false));
    try menu.appendChild(cx.allocator, try candidate(cx, "kubectl ", "describe pod", .builtin, "", false));
    try menu.appendChild(cx.allocator, try candidate(cx, "kubectl ", "exec -it /opt/deploy/", .path, "", false));

    // 底部快捷键行。
    const footer = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 13), .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try footer.appendChild(cx.allocator, try kbd(cx, "↑↓"));
    try footer.appendChild(cx.allocator, try ui.text(cx, "选择", .{ .font_size = 10, .color = tok.fg3 }));
    try footer.appendChild(cx.allocator, try kbd(cx, "→"));
    try footer.appendChild(cx.allocator, try ui.text(cx, "补全到行", .{ .font_size = 10, .color = tok.fg3 }));
    try footer.appendChild(cx.allocator, try kbd(cx, "↵"));
    try footer.appendChild(cx.allocator, try ui.text(cx, "执行", .{ .font_size = 10, .color = tok.fg3 }));
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    try footer.appendChild(cx.allocator, try ui.text(cx, "三级数据源: 历史 + SFTP路径 + 静态表(~500)", .{
        .font_size = 10,
        .color = tok.fg3,
    }));
    try menu.appendChild(cx.allocator, footer);
    return menu;
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
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.grn));
    try bar.appendChild(cx.allocator, try ui.text(cx, "已连接", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "补全: 开 · 零延迟本地预测，与远端 shell tab 补全正交共存", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
