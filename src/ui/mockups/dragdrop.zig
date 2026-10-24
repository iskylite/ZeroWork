//! mockup-dragdrop — 拖拽悬停设计稿复刻（docs/SPEC/html/mockup-dragdrop.html）。
//!
//! 结构：tbar(40) + term(560，内含拖拽覆盖层：accent 虚线框 + 上传确认 HUD 540 宽)
//! + sbar(28)。窗口 1280×628。
//! 差异记录：border 无 dashed 选项，2.5px dashed accent@25% 用 2px 实线 accent@25% 近似。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-dragdrop";

const tok = mock.tok;

// HTML 内联色（:root token 之外的补充）
const grn6 = ui.Color.rgb(0x05, 0x96, 0x69); // #059669（cn.dst / ec.iso 文字）
const c2563 = ui.Color.rgb(0x25, 0x63, 0xEB); // 主按钮渐变终点
const cn_bg = ui.Color.rgb(0xF4, 0xF8, 0xF6); // .cn 链路节点底

const tdim = tok.alpha(tok.fg, 140); // .td opacity .55

fn txt(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .font_weight = weight, .color = color, .line_height = 1.2 });
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40px：红绿灯 + 单页签） ───────────────────────────

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
    try tab.appendChild(cx.allocator, try txt(cx, "DB-Master (2级跳板) ✕", 12, 500, tok.fg));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区 + 拖拽覆盖层 ────────────────────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{});
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "dbadmin", .color = tok.cyn },
        .{ .text = "@db-master:", .color = tok.fg },
        .{ .text = "/opt/deploy", .color = tok.acc2 },
        .{ .text = "$ ls -la", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "drwxr-xr-x 4 root root 4096 Oct  8 12:00 .", .color = tdim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "-rw-r--r-- 1 root root  23M Oct  7 18:30 release-v2.3.0.tar.gz", .color = tdim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "-rwxr-xr-x 1 root root 1.2K Oct  8 10:00 deploy.sh", .color = tdim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "dbadmin", .color = tok.cyn },
        .{ .text = "@db-master:", .color = tok.fg },
        .{ .text = "/opt/deploy", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
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
        .glass = .{ .backdrop_blur = 6 },
        .z_index = 10,
    }, .{});
    // .ob：pane 内嵌虚线框（dashed 不可用 → 实线低透明度近似；absolute 需显式 fill 才拉伸）
    const ob = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 16 }, .right = .{ .px = 16 }, .bottom = .{ .px = 16 }, .left = .{ .px = 16 } },
        .width = .fill(),
        .height = .fill(),
        .border = .{ .width = 2, .color = tok.alpha(tok.acc, 64), .radius = 16 },
    }, .{});
    try ov.appendChild(cx.allocator, ob);
    try ov.appendChild(cx.allocator, try mountHud(cx));
    return ov;
}

// ── 上传确认 HUD（.hud 540 宽） ────────────────────────────────────

fn mountHud(cx: *ui.Cx) !*ui.Node {
    const hud = try ui.box(cx, .{
        .width = .{ .px = 540 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242), // rgba(248,255,251,.95)
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 18), .radius = 12 },
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(15, 23, 42, 36), .blur = 44, .offset_x = 0, .offset_y = 16 },
            .{ .color = ui.Color.rgba(15, 23, 42, 15), .blur = 8, .offset_x = 0, .offset_y = 2 },
        }),
        .padding = .{ .left = 28, .right = 28, .top = 24, .bottom = 24 },
        .z_index = 20,
        .flex_shrink = 0,
    }, .{});

    // 标题行：📥 上传到 DB-Master + ESC 取消
    const ht = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .margin = .{ .top = 0, .right = 0, .bottom = 18, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try ht.appendChild(cx.allocator, try txt(cx, "📥", 20, 400, tok.fg));
    try ht.appendChild(cx.allocator, try txt(cx, "上传到 DB-Master", 15, 600, tok.fg));
    const esc = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
        .background = ui.Color.rgba(0, 0, 0, 10), // rgba(0,0,0,.04)
        .border = .{ .width = 0, .color = tok.bd, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try esc.appendChild(cx.allocator, try txt(cx, "ESC 取消", 11, 400, tok.fg3));
    try ht.appendChild(cx.allocator, esc);
    try hud.appendChild(cx.allocator, ht);

    // 源文件行
    const r1 = try hrow(cx);
    try r1.appendChild(cx.allocator, try hlab(cx, "源文件"));
    const hfile = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 13, .right = 13, .top = 8, .bottom = 8 },
        .background = tok.alpha(tok.acc, 10), // rgba(19,69,246,.04)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 20), .radius = 10 }, // .08
    }, .{});
    try hfile.appendChild(cx.allocator, try txt(cx, "📦", 24, 400, tok.fg));
    const fmeta = try ui.box(cx, .{ .direction = .column, .flex_shrink = 0 }, .{});
    try fmeta.appendChild(cx.allocator, try txt(cx, "release-v2.4.0-darwin-arm64.tar.gz", 12.5, 500, tok.fg));
    const fs_node = try ui.box(cx, .{
        .margin = .{ .top = 1, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    try fs_node.appendChild(cx.allocator, try txt(cx, "48.6 MB · tar.gz 归档", 10.5, 400, tok.fg2));
    try fmeta.appendChild(cx.allocator, fs_node);
    try hfile.appendChild(cx.allocator, fmeta);
    try r1.appendChild(cx.allocator, hfile);
    try hud.appendChild(cx.allocator, r1);

    // 远程目标行
    const r2 = try hrow(cx);
    try r2.appendChild(cx.allocator, try hlab(cx, "远程目标"));
    try r2.appendChild(cx.allocator, try hin(cx, "/opt/deploy/release-v2.4.0.tar.gz"));
    try hud.appendChild(cx.allocator, r2);

    // 传输链路行
    const r3 = try hrow(cx);
    try r3.appendChild(cx.allocator, try hlab(cx, "传输链路"));
    const chain = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 5,
    }, .{});
    try chain.appendChild(cx.allocator, try cn(cx, "本机", false));
    try chain.appendChild(cx.allocator, try cnArr(cx));
    try chain.appendChild(cx.allocator, try cn(cx, "Bastion-01", false));
    try chain.appendChild(cx.allocator, try cnArr(cx));
    try chain.appendChild(cx.allocator, try cn(cx, "VPC-Transit", false));
    try chain.appendChild(cx.allocator, try cnArr(cx));
    try chain.appendChild(cx.allocator, try cn(cx, "DB-Master", true));
    try r3.appendChild(cx.allocator, chain);
    try hud.appendChild(cx.allocator, r3);

    // 引擎行
    const r4 = try hrow(cx);
    try r4.appendChild(cx.allocator, try hlab(cx, "引擎"));
    const chips = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 6,
    }, .{});
    try chips.appendChild(cx.allocator, try ec(cx, "SFTP", false));
    try chips.appendChild(cx.allocator, try ec(cx, "独立传输连接 · 不占用当前终端", true));
    try chips.appendChild(cx.allocator, try ec(cx, "16×64KB 窗口", false));
    try chips.appendChild(cx.allocator, try ec(cx, "断点续传", false));
    try r4.appendChild(cx.allocator, chips);
    try hud.appendChild(cx.allocator, r4);

    // 选项行
    const r5 = try hrow(cx);
    try r5.appendChild(cx.allocator, try hlab(cx, "选项"));
    const hchk = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 16,
    }, .{});
    try hchk.appendChild(cx.allocator, try hck(cx, "完成后通知", true));
    try hchk.appendChild(cx.allocator, try hck(cx, "校验 MD5（默认关）", false));
    try r5.appendChild(cx.allocator, hchk);
    try hud.appendChild(cx.allocator, r5);

    // 按钮行
    const act = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .align_items = .center,
        .gap = 10,
        .margin = .{ .top = 18, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 15, .bottom = 0 },
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 15), .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const cancel = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 22, .right = 22, .top = 9, .bottom = 9 },
        .background = ui.Color.rgba(0, 0, 0, 10),
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try cancel.appendChild(cx.allocator, try txt(cx, "取消", 13, 400, tok.fg2));
    try act.appendChild(cx.allocator, cancel);
    const upload = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 26, .right = 26, .top = 9, .bottom = 9 },
        .gradient = .{ .from = tok.acc, .to = c2563, .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = tok.alpha(tok.acc, 77) }, // rgba(19,69,246,.3)
        .flex_shrink = 0,
    }, .{});
    try upload.appendChild(cx.allocator, try txt(cx, "🚀 立即上传", 13, 600, tok.white));
    try act.appendChild(cx.allocator, upload);
    try hud.appendChild(cx.allocator, act);
    return hud;
}

// ── HUD 内部小部件 ────────────────────────────────────────────────

fn hrow(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .min_height = 32,
        .margin = .{ .top = 0, .right = 0, .bottom = 12, .left = 0 },
        .flex_shrink = 0,
    }, .{});
}

fn hlab(cx: *ui.Cx, s: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 70 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, s, 12, 400, tok.fg2));
    return node;
}

fn hin(cx: *ui.Cx, value: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, value, .{
        .font_size = 12,
        .color = tok.fg,
        .use_monospace_font = true,
        .line_height = 1.2,
    }));
    return node;
}

fn cn(cx: *ui.Cx, label: []const u8, dst: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = if (dst) tok.alpha(tok.grn, 20) else cn_bg,
        .border = .{
            .width = 1,
            .color = if (dst) tok.alpha(tok.grn, 64) else tok.bd,
            .radius = 5,
        },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, label, 10.5, 500, if (dst) grn6 else tok.fg));
    return node;
}

fn cnArr(cx: *ui.Cx) !*ui.Node {
    const node = try ui.box(cx, .{
        .padding = .{ .left = 1, .right = 1, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, "→", 10.5, 400, tok.fg3));
    return node;
}

fn ec(cx: *ui.Cx, label: []const u8, iso: bool) !*ui.Node {
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

fn hck(cx: *ui.Cx, label: []const u8, checked: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    const cbx = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .align_items = .center,
        .justify = .center,
        .background = if (checked) tok.acc else tok.white,
        .border = .{
            .width = if (checked) 0 else 1,
            .color = tok.bd,
            .radius = 4,
        },
        .flex_shrink = 0,
    }, .{});
    if (checked) {
        try cbx.appendChild(cx.allocator, try txt(cx, "✓", 10, 700, tok.white));
    }
    try node.appendChild(cx.allocator, cbx);
    try node.appendChild(cx.allocator, try txt(cx, label, 12, 400, tok.fg2));
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
    try bar.appendChild(cx.allocator, try txt(cx, "已连接: 2级跳板 → db-master  |  RTT 46ms  |  拖拽或 ", 11, 400, tok.fg2));
    try bar.appendChild(cx.allocator, try txt(cx, "@up", 11, 700, tok.fg2));
    try bar.appendChild(cx.allocator, try txt(cx, " 上传", 11, 400, tok.fg2));
    return bar;
}
