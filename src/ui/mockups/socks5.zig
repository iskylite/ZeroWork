//! mockup-socks5 — SOCKS5 信息卡设计稿复刻（docs/SPEC/html/mockup-socks5.html）。
//!
//! 结构：tbar(40) + term(560, sp 卡锚 right24 bottom34) + sbar(28)。窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-socks5";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_card = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242); // rgba(248,255,251,.95)
const c_card_border = tok.alpha(tok.acc, 26); // rgba(19,69,246,.1)
const c_line5 = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const c_grn_deep = ui.Color.rgb(0x05, 0x96, 0x69); // #059669

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏：DB-Master（on）+ VPC-Transit（暂停态） ─────────────────

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

    // tab1：🧦 DB-Master（on 样式）
    const tab1 = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab1.appendChild(cx.allocator, try ui.text(cx, "🧦 DB-Master ✕", .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab1);

    // tab2：🧦 VPC-Transit ◌ 转发已暂停(断线) ✕（inline 覆盖为 off 样式）
    const tab2 = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try tab2.appendChild(cx.allocator, try ui.text(cx, "🧦 VPC-Transit ", .{
        .font_size = 12, .color = tok.fg2,
    }));
    try tab2.appendChild(cx.allocator, try ui.text(cx, "◌ 转发已暂停(断线)", .{
        .font_size = 9, .color = tok.yel,
    }));
    try tab2.appendChild(cx.allocator, try ui.text(cx, " ✕", .{
        .font_size = 12, .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, tab2);

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区 + SOCKS5 信息卡 ─────────────────────────────────────────

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
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "dbadmin", .color = tok.cyn },
        .{ .text = "@db-master:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@socks on", .color = tok.acc, .weight = 600 },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] SOCKS5 动态转发已开启 → 127.0.0.1:1080 · 出口: 链路末端 DB-Master", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "          本机代理用法: export ALL_PROXY=socks5://127.0.0.1:1080", .color = td },
    }, .{}));
    // 输入行：png 中此行无 .input 高亮（普通行 + 块光标）
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "dbadmin", .color = tok.cyn },
        .{ .text = "@db-master:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = " ", .color = tok.fg },
    }, .{ .cursor = true }));

    try term.appendChild(cx.allocator, try mountSocksCard(cx));
    return term;
}

// ── SOCKS5 信息卡（sp：right 24 bottom 34，430 宽） ────────────────

fn mountSocksCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .position = .absolute,
        // term 560 高；卡高约 212（14+8+18+4*27+11+1+10+27+14）
        .inset = .{ .top = .{ .px = 314 }, .right = .{ .px = 24 } },
        .width = .{ .px = 430 },
        .direction = .column,
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) },
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 50,
        .padding = .{ .left = 18, .right = 18, .top = 14, .bottom = 14 },
    }, .{});

    // 指向状态栏 chip 的小箭头（::after：12² 旋转 45°，bottom -6 right 64）
    const arrow = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .bottom = .{ .px = -6 }, .right = .{ .px = 64 } },
        .width = .{ .px = 12 },
        .height = .{ .px = 12 },
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 0, .side_widths = .{ -1, 1, 1, -1 } }, // right+bottom
        .rotate = 0.785398, // 45°
        .z_index = 51,
    }, .{});
    try card.appendChild(cx.allocator, arrow);

    // 头部：🧦 SOCKS5 动态转发 + ● 运行中
    const head = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "🧦 SOCKS5 动态转发", .{
        .font_size = 12.5, .font_weight = 600, .color = tok.fg,
    }));
    try head.appendChild(cx.allocator, try ui.spacer(cx));
    try head.appendChild(cx.allocator, try ui.text(cx, "● 运行中", .{
        .font_size = 10, .font_weight = 600, .color = tok.grn,
    }));
    try card.appendChild(cx.allocator, head);

    // 信息行 ×4
    try card.appendChild(cx.allocator, try infoRowMono(cx, "监听地址", "127.0.0.1:1080", "仅本机 · 改绑 0.0.0.0 需红色确认", false));
    try card.appendChild(cx.allocator, try infoRowMono(cx, "出口节点", "DB-Master", "链路末端（经 Bastion-01 → VPC-Transit）", false));
    try card.appendChild(cx.allocator, try infoRowMono(cx, "实时统计", "活跃连接 3 · 已传输 12.4 MB", null, false));
    try card.appendChild(cx.allocator, try infoRowWarn(cx, "协议范围", "仅 TCP CONNECT · UDP 不支持（SSH 通道限制）"));

    // 按钮行
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .gap = 8,
        .margin = .{ .top = 11, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 10, .bottom = 0 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
    }, .{});
    try foot.appendChild(cx.allocator, try miniBtn(cx, "🔍 测试代理", .primary));
    try foot.appendChild(cx.allocator, try miniBtn(cx, "⧉ 复制 export 命令", .plain));
    try foot.appendChild(cx.allocator, try miniBtn(cx, "⚙ 改端口/出口", .plain));
    try foot.appendChild(cx.allocator, try ui.spacer(cx));
    try foot.appendChild(cx.allocator, try miniBtn(cx, "■ 停止", .danger));
    try card.appendChild(cx.allocator, foot);
    return card;
}

/// 信息行：k(72) + v(mono) + 注。warn=true 时注为黄色 600 级。
fn infoRowMono(cx: *ui.Cx, k: []const u8, v: []const u8, note: ?[]const u8, warn: bool) !*ui.Node {
    _ = warn;
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try keyCol(cx, k));
    try row.appendChild(cx.allocator, try ui.text(cx, v, .{
        .font_size = 10.5, .color = tok.fg, .use_monospace_font = true,
    }));
    if (note) |n| {
        try row.appendChild(cx.allocator, try ui.text(cx, n, .{
            .font_size = 9.5, .color = tok.fg3,
        }));
    }
    return row;
}

/// 警示行：k + 黄色 600 注（html .warn）。
fn infoRowWarn(cx: *ui.Cx, k: []const u8, v: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try keyCol(cx, k));
    try row.appendChild(cx.allocator, try ui.text(cx, v, .{
        .font_size = 9.5, .font_weight = 600, .color = tok.yel,
    }));
    return row;
}

fn keyCol(cx: *ui.Cx, k: []const u8) !*ui.Node {
    const col = try ui.box(cx, .{
        .width = .{ .px = 72 },
        .flex_shrink = 0,
    }, .{});
    try col.appendChild(cx.allocator, try ui.text(cx, k, .{
        .font_size = 10.5, .color = tok.fg2,
    }));
    return col;
}

/// 小按钮（sb2）：padding 5 12 / 圆角 7 / 10.5·500。
const BtnKind = enum { primary, plain, danger };

fn miniBtn(cx: *ui.Cx, label: []const u8, kind: BtnKind) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 25 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = switch (kind) {
            .primary => tok.alpha(tok.grn, 20), // rgba(16,185,129,.08)
            .plain => ui.Color.rgb(0xF8, 0xFA, 0xFC), // #F8FAFC
            .danger => ui.Color.TRANSPARENT,
        },
        .border = .{ .width = 1, .color = switch (kind) {
            .primary => tok.alpha(tok.grn, 64), // rgba(16,185,129,.25)
            .plain => tok.bd,
            .danger => tok.alpha(tok.red, 64), // rgba(220,76,63,.25)
        }, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .font_weight = 500,
        .color = switch (kind) {
            .primary => c_grn_deep,
            .plain => tok.fg2,
            .danger => tok.red,
        },
    }));
    return node;
}

// ── 状态栏：链路 + RTT + SOCKS chip ────────────────────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "Bastion-01 → db-master", .{
        .font_size = 11, .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "RTT 46ms", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "120×36", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    // 🧦 SOCKS chip（acc 600，底 acc.1，环 1.5px acc.35）
    const sock = try ui.box(cx, .{
        .height = .{ .px = 21 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 26), // rgba(19,69,246,.1)
        .border = .{ .width = 0, .color = tok.acc, .radius = 10 },
        .shadow = .{ .blur = 0, .offset_x = 0, .offset_y = 0, .spread = 1.5, .color = tok.alpha(tok.acc, 89) }, // rgba(19,69,246,.35)
        .flex_shrink = 0,
    }, .{});
    try sock.appendChild(cx.allocator, try ui.text(cx, "🧦 SOCKS5 :1080 ● 3", .{
        .font_size = 11, .font_weight = 600, .color = tok.acc,
    }));
    try bar.appendChild(cx.allocator, sock);
    return bar;
}
