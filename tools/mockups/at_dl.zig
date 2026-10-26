//! mockup-at-dl — 统一传输面板·下载设计稿复刻（docs/SPEC/html/mockup-at-dl.html）。
//!
//! HTML .win 为 1100 宽（预览窗固定 1280），故窗口卡 1100 宽居中于 #888 画布底。
//! 结构：tbar(40) + term(560，内含 ov[下载卡片 520 宽：多重命名行]) + sbar(28)。
//! 窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-at-dl";

const tok = mock.tok;

// HTML 内联色（:root token 之外的补充）
const grn6 = ui.Color.rgb(0x05, 0x96, 0x69); // #059669（chip.iso 文字）
const c2563 = ui.Color.rgb(0x25, 0x63, 0xEB); // 主按钮渐变终点

const tdim = tok.alpha(tok.fg, 140); // .td opacity .55

fn txt(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .font_weight = weight, .color = color, .line_height = 1.2 });
}

fn mono(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{
        .font_size = size,
        .font_weight = weight,
        .color = color,
        .use_monospace_font = true,
        .line_height = 1.2,
    });
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    // body{background:#888} 画布 + .win(1100×628) 居中
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .background = ui.Color.rgb(0x88, 0x88, 0x88),
        .overflow = .hidden,
    }, .{});
    const win = try ui.box(cx, .{
        .width = .{ .px = 1100 },
        .height = .{ .px = 628 },
        .direction = .column,
        .background = tok.bg,
        .border = .{ .width = 0, .color = tok.bd, .radius = 12 },
        .shadow = .{ .blur = 60, .offset_y = 25, .color = ui.Color.rgba(0, 0, 0, 77) },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
    try root.appendChild(cx.allocator, win);
    return root;
}

// ── 标题栏（tbar 40px：红绿灯 + K8s-Node01 页签 + 右侧全局图标） ──

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
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try txt(cx, "K8s-Node01", 12, 500, tok.fg));
    try tab.appendChild(cx.allocator, try txt(cx, "✕", 12, 400, tok.fg));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try icn(cx, "⚡", false));
    try bar.appendChild(cx.allocator, try icn(cx, "⇅", false));
    try bar.appendChild(cx.allocator, try icn(cx, "✨", true));
    try bar.appendChild(cx.allocator, try icn(cx, "⚙️", false));
    return bar;
}

fn icn(cx: *ui.Cx, icon: []const u8, acc: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, icon, 14, 400, if (acc) tok.acc else tok.fg2));
    return node;
}

// ── 终端区 + 面板覆盖层 ────────────────────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{});
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ls -lh /var/log/app.log", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "-rw-r----- 1 root adm 18M Oct 8 14:02 /var/log/app.log", .color = tdim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@dl /var/log/app.log", .color = tok.acc, .weight = 600 },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 内置指令 · 打开统一传输面板（下载模式）", .color = tdim },
    }, .{}));
    try term.appendChild(cx.allocator, try mountOverlay(cx));
    return term;
}

fn mountOverlay(cx: *ui.Cx) !*ui.Node {
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .background = tok.alpha(tok.bg, 102), // rgba(236,255,244,.4)
        .glass = .{ .backdrop_blur = 4 },
        .z_index = 10,
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    return ov;
}

// ── 下载卡片（520 宽） ─────────────────────────────────────────────

fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 520 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242), // rgba(248,255,251,.95)
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 18), .radius = 12 },
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(15, 23, 42, 36), .blur = 44, .offset_x = 0, .offset_y = 16 },
            .{ .color = ui.Color.rgba(15, 23, 42, 15), .blur = 8, .offset_x = 0, .offset_y = 2 },
        }),
        .padding = .{ .left = 24, .right = 24, .top = 20, .bottom = 20 },
        .z_index = 20,
        .flex_shrink = 0,
    }, .{});

    // 标题行：📥 下载 + 副注 + ESC 取消
    const ht = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 14, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try ht.appendChild(cx.allocator, try txt(cx, "📥 下载", 14, 600, tok.fg));
    try ht.appendChild(cx.allocator, try txt(cx, "统一传输面板 · 下载模式", 10, 400, tok.fg3));
    const esc = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 3, .bottom = 3 },
        .background = ui.Color.rgba(0, 0, 0, 10), // rgba(0,0,0,.04)
        .border = .{ .width = 0, .color = tok.bd, .radius = 5 },
        .flex_shrink = 0,
    }, .{});
    try esc.appendChild(cx.allocator, try txt(cx, "ESC 取消", 10, 400, tok.fg3));
    try ht.appendChild(cx.allocator, esc);
    try card.appendChild(cx.allocator, ht);

    // 远程文件行
    const r1 = try row(cx);
    try r1.appendChild(cx.allocator, try lab(cx, "远程文件"));
    try r1.appendChild(cx.allocator, try mono(cx, "/var/log/app.log", 12, 400, tok.fg));
    try r1.appendChild(cx.allocator, try txt(cx, "18 MB", 10.5, 400, tok.fg2));
    try card.appendChild(cx.allocator, r1);

    // 保存目录行
    const r2 = try row(cx);
    try r2.appendChild(cx.allocator, try lab(cx, "保存目录"));
    try r2.appendChild(cx.allocator, try inp(cx, "~/Downloads/"));
    try r2.appendChild(cx.allocator, try cbtn(cx, "更改…", 12, 12));
    try card.appendChild(cx.allocator, r2);

    // 重命名行
    const r3 = try row(cx);
    try r3.appendChild(cx.allocator, try lab(cx, "重命名"));
    try r3.appendChild(cx.allocator, try inp(cx, "app-k8s-node01-1008.log"));
    try r3.appendChild(cx.allocator, try txt(cx, "默认可改名", 10, 400, tok.fg3));
    try card.appendChild(cx.allocator, r3);

    // 来源链路行
    const r4 = try row(cx);
    try r4.appendChild(cx.allocator, try lab(cx, "来源链路"));
    try r4.appendChild(cx.allocator, try txt(cx, "K8s-Node01 · 经 Bastion-01 隧道", 10.5, 400, tok.fg2));
    try card.appendChild(cx.allocator, r4);

    // 传输行：引擎 chips
    const r5 = try row(cx);
    try r5.appendChild(cx.allocator, try lab(cx, "传输"));
    try r5.appendChild(cx.allocator, try chip(cx, "SFTP", false));
    try r5.appendChild(cx.allocator, try chip(cx, "独立连接", true));
    try r5.appendChild(cx.allocator, try chip(cx, "MD5 校验(默认关)", false));
    try card.appendChild(cx.allocator, r5);

    // 按钮行
    const act = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .align_items = .center,
        .gap = 9,
        .margin = .{ .top = 12, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 12, .bottom = 0 },
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 15), .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try act.appendChild(cx.allocator, try cbtn(cx, "取消", 18, 18));
    try act.appendChild(cx.allocator, try primaryBtn(cx, "⬇ 开始下载 ↵"));
    try card.appendChild(cx.allocator, act);
    return card;
}

// ── 卡片内通用小部件 ──────────────────────────────────────────────

fn row(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .margin = .{ .top = 0, .right = 0, .bottom = 11, .left = 0 },
        .flex_shrink = 0,
    }, .{});
}

fn lab(cx: *ui.Cx, s: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 64 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, s, 11.5, 400, tok.fg2));
    return node;
}

fn inp(cx: *ui.Cx, value: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 11, .right = 11, .top = 7, .bottom = 7 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
    }, .{});
    try node.appendChild(cx.allocator, try mono(cx, value, 12, 400, tok.fg));
    return node;
}

fn cbtn(cx: *ui.Cx, label: []const u8, pad_l: f32, pad_r: f32) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = pad_l, .right = pad_r, .top = 7, .bottom = 7 },
        .background = ui.Color.rgba(0, 0, 0, 10), // rgba(0,0,0,.04)
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, label, 12, 400, tok.fg2));
    return node;
}

fn primaryBtn(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 18, .right = 18, .top = 7, .bottom = 7 },
        .gradient = .{ .from = tok.acc, .to = c2563, .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = tok.alpha(tok.acc, 64) },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, label, 12, 600, tok.white));
    return node;
}

fn chip(cx: *ui.Cx, label: []const u8, iso: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = if (iso) tok.alpha(tok.grn, 18) else tok.alpha(tok.acc, 13),
        .border = .{
            .width = 1,
            .color = if (iso) tok.alpha(tok.grn, 51) else tok.alpha(tok.acc, 31),
            .radius = 5,
        },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, label, 10.5, 500, if (iso) grn6 else tok.acc));
    return node;
}

// ── 状态栏（sbar 28px） ────────────────────────────────────────────

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
    try bar.appendChild(cx.allocator, try txt(cx, "@dl <远程路径> [本地目录] · 保存目录可选 + 支持重命名 · 与 @up/拖拽共用面板", 11, 400, tok.fg2));
    return bar;
}
