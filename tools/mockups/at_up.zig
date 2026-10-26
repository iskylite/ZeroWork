//! mockup-at-up — 统一传输面板·上传设计稿复刻（docs/SPEC/html/mockup-at-up.html）。
//!
//! HTML .win 为 1100 宽（预览窗固定 1280），故窗口卡 1100 宽居中于 #888 画布底。
//! 结构：tbar(40) + term(560，内含 ov[上传卡片 520 宽 + 最近使用下拉]) + sbar(28)。
//! 窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-at-up";

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
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@up", .color = tok.acc, .weight = 600 },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 内置指令 · 未携带路径 → 打开文件选择（与拖拽/⌘U 复用同一传输面板）", .color = tdim },
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

// ── 上传卡片（520 宽） ─────────────────────────────────────────────

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

    // 标题行：📤 上传 + 副注 + ESC 取消
    const ht = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 14, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try ht.appendChild(cx.allocator, try txt(cx, "📤 上传", 14, 600, tok.fg));
    try ht.appendChild(cx.allocator, try txt(cx, "统一传输面板 · 与拖拽/⌘U 同组件", 10, 400, tok.fg3));
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

    // 源文件行：输入框 + 浏览… + 最近使用下拉（绝对定位，锚定本行 left 74 / top 34）
    const r1 = try row(cx);
    try r1.appendChild(cx.allocator, try lab(cx, "源文件"));
    try r1.appendChild(cx.allocator, try inp(cx, "（点击选择本地文件，支持多选）", tok.fg3));
    try r1.appendChild(cx.allocator, try cbtn(cx, "浏览…", 14, 14));
    try r1.appendChild(cx.allocator, try mountRecentDropdown(cx));
    try card.appendChild(cx.allocator, r1);

    // 150px 空档（html 的空 div，给绝对定位下拉留视觉空间）
    const gap = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 150 },
        .flex_shrink = 0,
    }, .{});
    try card.appendChild(cx.allocator, gap);

    // 远程目录行
    const r2 = try row(cx);
    try r2.appendChild(cx.allocator, try lab(cx, "远程目录"));
    try r2.appendChild(cx.allocator, try inp(cx, "/home/ubuntu/", tok.fg));
    try r2.appendChild(cx.allocator, try txt(cx, "跟随终端目录", 10, 400, tok.fg3));
    try card.appendChild(cx.allocator, r2);

    // 传输行：引擎 chips
    const r3 = try row(cx);
    try r3.appendChild(cx.allocator, try lab(cx, "传输"));
    try r3.appendChild(cx.allocator, try chip(cx, "SFTP", false));
    try r3.appendChild(cx.allocator, try chip(cx, "独立连接 · 不占用终端", true));
    try r3.appendChild(cx.allocator, try chip(cx, "断点续传", false));
    try card.appendChild(cx.allocator, r3);

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
    try act.appendChild(cx.allocator, try primaryBtn(cx, "🚀 开始上传 ↵"));
    try card.appendChild(cx.allocator, act);
    return card;
}

// ── 最近使用下拉（宽 360） ─────────────────────────────────────────

fn mountRecentDropdown(cx: *ui.Cx) !*ui.Node {
    const dd = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 34 }, .left = .{ .px = 74 } },
        .width = .{ .px = 360 },
        .direction = .column,
        .background = tok.white,
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 20), .radius = 10 }, // .08
        .shadow = .{ .blur = 32, .offset_y = 12, .color = ui.Color.rgba(15, 23, 42, 36) },
        .padding = .{ .left = 5, .right = 5, .top = 5, .bottom = 5 },
        .z_index = 30,
        .flex_shrink = 0,
    }, .{});
    const head = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try txt(cx, "最近使用 · 也可唤起 macOS 原生选择器（多选）", 9.5, 400, tok.fg3));
    try dd.appendChild(cx.allocator, head);
    try dd.appendChild(cx.allocator, try ddItem(cx, "📦", "release-v2.4.0.tar.gz", "48.6 MB · 桌面"));
    try dd.appendChild(cx.allocator, try ddItem(cx, "📄", "deploy.sh", "1.2 KB · ~/scripts"));
    try dd.appendChild(cx.allocator, try ddItem(cx, "📁", "dist/（整个目录）", "112 MB · 递归上传"));
    try dd.appendChild(cx.allocator, try ddItem(cx, "🖼️", "screenshot-final.png", "2.1 MB · 图片"));
    return dd;
}

fn ddItem(cx: *ui.Cx, icon: []const u8, name: []const u8, note: []const u8) !*ui.Node {
    const item = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try item.appendChild(cx.allocator, try txt(cx, icon, 11.5, 400, tok.fg));
    try item.appendChild(cx.allocator, try mono(cx, name, 11, 400, tok.fg));
    try item.appendChild(cx.allocator, try ui.spacer(cx));
    try item.appendChild(cx.allocator, try txt(cx, note, 9.5, 400, tok.fg3));
    return item;
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

fn inp(cx: *ui.Cx, value: []const u8, color: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 11, .right = 11, .top = 7, .bottom = 7 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
    }, .{});
    try node.appendChild(cx.allocator, try mono(cx, value, 12, 400, color));
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
    try bar.appendChild(cx.allocator, try txt(cx, "@up [路径] · 无参时弹文件选择（最近列表 + 原生选择器）· @up @dl 拖拽共用此面板", 11, 400, tok.fg2));
    return bar;
}
