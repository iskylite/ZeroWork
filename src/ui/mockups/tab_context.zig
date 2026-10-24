//! mockup-tab-context — 页签右键菜单设计稿复刻（docs/SPEC/html/mockup-tab-context.html）。
//!
//! 结构：tbar(40) + bodyc(560，含 dimo 压暗层 + 5 行终端) + sbar(28)，ctx 菜单
//! 与 pt toast 为绝对浮层。窗口 1280×628。
//!
//! HTML 语义对照：
//!  - .ctx：top 46 / left 300，宽 246，rgba(248,255,251,.95)+blur(24) 圆角 12，
//!    双层阴影，边 1px rgba(15,23,42,.07)，padding 5，z-index 50；
//!  - .ctx-h：头部 flex 左右两列（左标题列 + 右 mm 胶囊，均窄列折行），
//!    下边线 rgba(0,0,0,.05)，margin-bottom 4；.mm 胶囊 acc.08 底、acc 字、
//!    字 600、padding 1×7、圆角 4；
//!  - .ci：项（本稿无 hover 高亮），padding 6 10、gap 9、圆角 8、icon 16 列、
//!    sc 右注 10.5 #94A3B8；.ci.danger 红字；
//!  - .cs 分隔线 1px margin 4 8 rgba(0,0,0,.06)；
//!  - .sws：色板行 padding 7 10 gap 7；.sw 17² 圆、sel 外环 2px --fg；
//!  - .dimo：终端压暗层 rgba(236,255,244,.45)；
//!  - .pt：右上 toast rgba(15,23,42,.92) 白字 11 圆角 8。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-tab-context";

const tok = mock.tok;

// 菜单卡底色 rgba(248,255,251,.95)
const menu_bg = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242);
// 分隔线 rgba(0,0,0,.06)
const sep_col = ui.Color.rgba(0, 0, 0, 15);
// ctx-h 下边线 rgba(0,0,0,.05)
const h_line = ui.Color.rgba(0, 0, 0, 13);
// 菜单边框 rgba(15,23,42,.07)
const menu_bd = ui.Color.rgba(0x0F, 0x17, 0x2A, 18);
// sc / 说明字 #94A3B8
const note = ui.Color.rgb(0x94, 0xA3, 0xB8);

const tdim = tok.alpha(tok.fg, 140); // .td opacity .55

fn txt(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .font_weight = weight, .color = color, .line_height = 1.2 });
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
        try mountStatusBar(cx),
        try mountMenu(cx),
        try mountToast(cx),
    });
}

// ── 标题栏（tbar 40px：红绿灯 + 3 页签 + 全局图标） ────────────────

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

    // 页签 ×3：生产网关(off) / K8s-Node01(on) / RDS-PG(off)
    try bar.appendChild(cx.allocator, try tab(cx, "生产网关", false, tok.grn));
    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01", true, tok.grn));
    try bar.appendChild(cx.allocator, try tab(cx, "RDS-PG", false, tok.off_dot));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));

    // 右侧全局图标：⚡ ⇅ ✨(acc) ⚙️
    try bar.appendChild(cx.allocator, try icn(cx, "⚡", tok.fg2));
    try bar.appendChild(cx.allocator, try icn(cx, "⇅", tok.fg2));
    try bar.appendChild(cx.allocator, try icn(cx, "✨", tok.acc));
    try bar.appendChild(cx.allocator, try icn(cx, "⚙️", tok.fg2));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool, dot_color: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = .{ .width = if (on) 1.5 else 0, .color = if (on) tok.acc else tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try mock.dot(cx, 6, dot_color));
    try node.appendChild(cx.allocator, try txt(cx, name, 12, if (on) 500 else 400, if (on) tok.fg else tok.fg2));
    try node.appendChild(cx.allocator, try txt(cx, "✕", 9, 400, tok.fg3));
    return node;
}

fn icn(cx: *ui.Cx, icon: []const u8, color: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, icon, 14, 400, color));
    return node;
}

// ── 终端区（bodyc 560px：dimo 压暗层 + 5 行） ───────────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    const body = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    // dimo 压暗层（padding 区之上整体覆盖）
    const dimo = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .background = tok.alpha(tok.bg, 115), // rgba(236,255,244,.45)
    }, .{});
    try body.appendChild(cx.allocator, dimo);

    try body.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl top nodes", .color = tok.fg },
    }, .{}));
    try body.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "NAME         CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%", .color = tdim },
    }, .{}));
    try body.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "k8s-node01   412m         21%    8452Mi          27%", .color = tdim },
    }, .{}));
    try body.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "k8s-node02   388m         19%    7901Mi          25%", .color = tdim },
    }, .{}));
    try body.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));
    return body;
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
    try bar.appendChild(cx.allocator, try txt(cx, "已连接: Bastion-01 → k8s-node01", 11, 400, tok.fg2));
    try bar.appendChild(cx.allocator, try txt(cx, "|", 11, 400, tok.fg2));
    try bar.appendChild(cx.allocator, try txt(cx, "RTT 24ms", 11, 400, tok.fg2));
    return bar;
}

// ── 右键菜单浮层（.ctx：top 46 / left 300，宽 246） ────────────────

fn mountMenu(cx: *ui.Cx) !*ui.Node {
    const menu = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 46 }, .left = .{ .px = 300 } },
        .z_index = 50,
        .width = .{ .px = 246 },
        .direction = .column,
        .padding = .{ .left = 5, .right = 5, .top = 5, .bottom = 5 },
        .background = menu_bg,
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = menu_bd, .radius = 12 },
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36), .blur = 44, .offset_x = 0, .offset_y = 16 },
            .{ .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 15), .blur = 8, .offset_x = 0, .offset_y = 2 },
        }),
        .overflow = .hidden,
    }, .{});
    try menu.appendChild(cx.allocator, try ctxHeader(cx));
    try menu.appendChild(cx.allocator, try ci(cx, 31, "✏️", "重命名页签", null, false));
    try menu.appendChild(cx.allocator, try ci(cx, 31, "🖥️", "新建同主机会话", "@new", false));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "⧉", "镜像复制此会话", "@dup", false));
    try menu.appendChild(cx.allocator, try csSep(cx));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "⚙️", "编辑连接配置…", null, false));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "🔗", "查看跳板链路 (2 跳)", null, false));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "🎨", "会话主题 / 页签颜色…", "▸", false));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "🧦", "开启 SOCKS5 转发…", "@socks on", false));
    try menu.appendChild(cx.allocator, try csSep(cx));
    try menu.appendChild(cx.allocator, try swatchLabel(cx));
    try menu.appendChild(cx.allocator, try swatchRow(cx));
    try menu.appendChild(cx.allocator, try csSep(cx));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "👥", "加入终端组 (广播)", "⌘⇧I", false));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "🕐", "显示时间戳", null, false));
    try menu.appendChild(cx.allocator, try ci(cx, 32, "📜", "导出会话日志…", null, false));
    try menu.appendChild(cx.allocator, try csSep(cx));
    try menu.appendChild(cx.allocator, try ci(cx, 29, "✕", "关闭其他页签", null, false));
    try menu.appendChild(cx.allocator, try ci(cx, 28, "⏻", "断开并关闭", "⌘W", true));
    return menu;
}

/// 头部 .ctx-h：flex 左右两列（左标题列 2 行 / 右 mm 胶囊 2 行），下边线，margin-bottom 4。
/// 基准：PNG 实测行盒 16/17（10px 字 + 1.2 行距 + emoji 抬升），两列内容顶部对齐。
fn ctxHeader(cx: *ui.Cx) !*ui.Node {
    const h = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 45 },
        .direction = .row,
        .align_items = .start,
        .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 6 },
        .border = .{ .width = 1, .color = h_line, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    // 左列：🗂 页签菜单 · 会话生命周期与配置（折 2 行，10px 700 note 色）
    const title_col = try ui.box(cx, .{
        .width = .{ .px = 137 },
        .direction = .column,
        .flex_shrink = 0,
    }, .{});
    try title_col.appendChild(cx.allocator, try txt(cx, "🗂 页签菜单 · 会话生命周期与配置", 10, 700, note));
    try h.appendChild(cx.allocator, title_col);
    // 右列：mm 胶囊（acc.08 底 + acc 600 字 10px + padding 1×7 圆角 4，折 2 行）
    const mm = try ui.box(cx, .{
        .width = .{ .px = 83 },
        .direction = .column,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 1, .bottom = 1 },
        .background = tok.alpha(tok.acc, 20),
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try mm.appendChild(cx.allocator, try txt(cx, "右键打开 · 中键关闭", 10, 600, tok.acc));
    try h.appendChild(cx.allocator, mm);
    return h;
}

/// 菜单项 .ci：padding 6 10，icon 16 列，label 12.5，sc 右注 10.5 #94A3B8。
fn ci(cx: *ui.Cx, row_h: f32, icon: []const u8, label: []const u8, sc: ?[]const u8, danger: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = row_h },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .border = .{ .width = 0, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 16 },
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try txt(cx, icon, 12, 400, if (danger) tok.red else tok.fg2));
    try row.appendChild(cx.allocator, ic);
    try row.appendChild(cx.allocator, try txt(cx, label, 12.5, 400, if (danger) tok.red else tok.fg));
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    if (sc) |s| {
        try row.appendChild(cx.allocator, try txt(cx, s, 10.5, 400, note));
    }
    return row;
}

/// 分隔线 .cs：1px，margin 4 8。
fn csSep(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .margin = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 },
        .background = sep_col,
        .flex_shrink = 0,
    }, .{});
}

/// 「页签颜色」小标签：padding 4 10 2，10.5px #94A3B8。
fn swatchLabel(cx: *ui.Cx) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 17 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 2 },
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try txt(cx, "页签颜色", 10.5, 400, note));
    return row;
}

/// 色板行 .sws：padding 7 10，gap 7；.sw 17² 圆，sel 外环 2px --fg。
fn swatchRow(cx: *ui.Cx) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 7 },
        .flex_shrink = 0,
    }, .{});
    const sel_border = tok.fg;
    const colors = [_]struct { c: ui.Color, sel: bool }{
        .{ .c = ui.Color.rgb(0x94, 0xA3, 0xB8), .sel = false },
        .{ .c = tok.acc, .sel = true },
        .{ .c = tok.grn, .sel = false },
        .{ .c = ui.Color.rgb(0xD4, 0x9A, 0x0C), .sel = false },
        .{ .c = ui.Color.rgb(0xDC, 0x4C, 0x3F), .sel = false },
        .{ .c = ui.Color.rgb(0xC2, 0x41, 0xE0), .sel = false },
    };
    for (colors) |entry| {
        const sw = try ui.box(cx, .{
            .width = .{ .px = 17 },
            .height = .{ .px = 17 },
            .background = entry.c,
            .border = if (entry.sel) .{ .width = 2, .color = sel_border, .radius = 8.5 } else .{ .width = 2, .color = ui.Color.TRANSPARENT, .radius = 8.5 },
            .flex_shrink = 0,
        }, .{});
        try row.appendChild(cx.allocator, sw);
    }
    return row;
}

// ── 右上角 toast（.pt：right 26 / top 90） ─────────────────────────

fn mountToast(cx: *ui.Cx) !*ui.Node {
    const toast = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 90 }, .right = .{ .px = 26 } },
        .z_index = 40,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
        .background = ui.Color.rgba(0x0F, 0x17, 0x2A, 235), // rgba(15,23,42,.92)
        .border = .{ .width = 0, .color = tok.fg, .radius = 8 },
        .shadow = .{ .blur = 20, .offset_y = 8, .color = ui.Color.rgba(0, 0, 0, 64) },
    }, .{});
    try toast.appendChild(cx.allocator, try txt(cx, "Terminal 区：右键=复制/粘贴 · 中键=终端菜单（与 Tab 菜单区分）", 11, 400, tok.white));
    return toast;
}
