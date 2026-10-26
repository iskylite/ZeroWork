//! mockup-socks5-config — SOCKS5 配置模态设计稿复刻（docs/SPEC/html/mockup-socks5-config.html）。
//!
//! 结构：tbar(40) + term(560, ov 居中 440 配置卡) + sbar(28)。窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-socks5-config";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_card = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242); // rgba(248,255,251,.95)
const c_card_border = tok.alpha(tok.acc, 26); // rgba(19,69,246,.1)
const c_row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // #F2F9F4

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

    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "DB-Master ✕", .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区 + 配置模态 ──────────────────────────────────────────────

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
        .{ .text = "[ZeroWork] SOCKS5 动态转发已开启 → 127.0.0.1:1080", .color = td },
    }, .{}));

    // ov 压暗层 + 居中卡
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 1280 },
        .height = .{ .px = 560 },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(0xEC, 0xFF, 0xF4, 115), // rgba(236,255,244,.45)
        .glass = .{ .backdrop_blur = 4 },
        .z_index = 10,
    }, .{});
    try ov.appendChild(cx.allocator, try mountConfigCard(cx));
    try term.appendChild(cx.allocator, ov);
    return term;
}

// ── 配置卡（440 宽，padding 18 22） ─────────────────────────────────

fn mountConfigCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 440 },
        .direction = .column,
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) },
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 20,
        .padding = .{ .left = 22, .right = 22, .top = 18, .bottom = 18 },
    }, .{});

    // 标题 + 副题
    const head = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "🧦 转发配置 — DB-Master", .{
        .font_size = 13.5, .font_weight = 600, .color = tok.fg,
    }));
    try card.appendChild(cx.allocator, head);
    const sub = try ui.box(cx, .{
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
    }, .{});
    try sub.appendChild(cx.allocator, try ui.text(cx, "信息卡「改端口/出口」或连接配置进入 · 改后即时生效", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try card.appendChild(cx.allocator, sub);

    // 行1：本地端口
    try card.appendChild(cx.allocator, try fieldRowInput(cx, "本地端口", "1080", "冲突自动 +1", false));
    // 行2：绑定地址
    try card.appendChild(cx.allocator, try fieldRowInput(cx, "绑定地址", "127.0.0.1", "改 0.0.0.0 将暴露局域网 ⚠", true));
    // 行3：出口节点（Inter 字体下拉）
    try card.appendChild(cx.allocator, try fieldRowDropdown(cx, "出口节点", "链路末端（DB-Master） ▾", "可选任一已认证跳"));
    // 行4：自动开启（toggle off）
    try card.appendChild(cx.allocator, try fieldRowToggle(cx, "自动开启", "建连成功即起转发（含重连恢复）"));
    // 行5：并发软上限（无下边线）
    try card.appendChild(cx.allocator, try fieldRowLast(cx, "并发软上限", "64", "防中间跳 MaxSessions 打满"));

    // 保存勾选行
    const save = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .margin = .{ .top = 10, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    // 15² 勾选框（acc 底 白 ✓ 字 10）
    const cb = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .align_items = .center,
        .justify = .center,
        .background = tok.acc,
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try cb.appendChild(cx.allocator, try ui.text(cx, "✓", .{
        .font_size = 10, .color = tok.white,
    }));
    try save.appendChild(cx.allocator, cb);
    try save.appendChild(cx.allocator, try ui.text(cx, "保存到主机配置（下次连接沿用）", .{
        .font_size = 10.5, .color = tok.fg2,
    }));
    try card.appendChild(cx.allocator, save);

    // 按钮行（右对齐）
    const btns = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .gap = 9,
        .margin = .{ .top = 14, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    // 取消（.btn）
    const cancel = try ui.box(cx, .{
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 16, .right = 16, .top = 0, .bottom = 0 },
        .background = ui.Color.rgba(0, 0, 0, 8), // rgba(0,0,0,.03)
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try cancel.appendChild(cx.allocator, try ui.text(cx, "取消", .{
        .font_size = 12, .color = tok.fg2,
    }));
    try btns.appendChild(cx.allocator, cancel);
    // 应用 ↵（.btn.p：渐变+白 600）
    const apply = try ui.box(cx, .{
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 16, .right = 16, .top = 0, .bottom = 0 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try apply.appendChild(cx.allocator, try ui.text(cx, "应用 ↵", .{
        .font_size = 12, .font_weight = 600, .color = tok.white,
    }));
    try btns.appendChild(cx.allocator, apply);
    try card.appendChild(cx.allocator, btns);
    return card;
}

/// 行容器：label(88) + 控件 + 注。
fn fieldShell(cx: *ui.Cx, label: []const u8, sep: bool, children: anytype) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 7, .bottom = 7 },
        .border = if (sep) .{ .width = 1, .color = c_row_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } } else null,
        .flex_shrink = 0,
    }, .{});
    const lab = try ui.box(cx, .{
        .width = .{ .px = 88 },
        .flex_shrink = 0,
    }, .{});
    try lab.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11.5, .color = tok.fg2,
    }));
    try row.appendChild(cx.allocator, lab);
    inline for (children) |ch| {
        try row.appendChild(cx.allocator, ch);
    }
    return row;
}

/// 输入框（.inp）：flex1 高 27 mono 11.5 白底。
fn inputField(cx: *ui.Cx, value: []const u8, mono: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .flex = 1,
        .height = .{ .px = 27 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .min_width = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, value, .{
        .font_size = 11.5, .color = tok.fg, .use_monospace_font = mono,
    }));
    return node;
}

/// 行注（9.5 fg3 / yel 600）。
fn fieldNote(cx: *ui.Cx, text: []const u8, warn: bool) !*ui.Node {
    const n = try ui.box(cx, .{ .flex_shrink = 0 }, .{});
    try n.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 9.5,
        .font_weight = if (warn) 600 else 400,
        .color = if (warn) tok.yel else tok.fg3,
    }));
    return n;
}

fn fieldRowInput(cx: *ui.Cx, label: []const u8, value: []const u8, note: []const u8, warn: bool) !*ui.Node {
    const inp = try inputField(cx, value, true);
    const nt = try fieldNote(cx, note, warn);
    return fieldShell(cx, label, true, .{ inp, nt });
}

fn fieldRowDropdown(cx: *ui.Cx, label: []const u8, value: []const u8, note: []const u8) !*ui.Node {
    // 出口节点为 Inter 字体（html inline font-family 覆盖）
    const inp = try inputField(cx, value, false);
    const nt = try fieldNote(cx, note, false);
    return fieldShell(cx, label, true, .{ inp, nt });
}

fn fieldRowToggle(cx: *ui.Cx, label: []const u8, note: []const u8) !*ui.Node {
    const tgl = try mock.toggle(cx, false);
    const nt = try ui.box(cx, .{ .flex_shrink = 0 }, .{});
    try nt.appendChild(cx.allocator, try ui.text(cx, note, .{
        .font_size = 10, .color = tok.fg3,
    }));
    return fieldShell(cx, label, true, .{ tgl, nt });
}

fn fieldRowLast(cx: *ui.Cx, label: []const u8, value: []const u8, note: []const u8) !*ui.Node {
    const inp = try inputField(cx, value, true);
    const nt = try fieldNote(cx, note, false);
    return fieldShell(cx, label, false, .{ inp, nt });
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "SOCKS5 转发配置模态 · 即时生效 · 可选写回主机配置", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
