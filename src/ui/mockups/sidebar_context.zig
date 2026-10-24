//! mockup-sidebar-context — 侧栏主机右键菜单设计稿复刻（docs/SPEC/html/mockup-sidebar-context.html）。
//!
//! 结构：tbar(40) + main(600: sb 224 + tp) + sbar(28)，菜单浮层 .menu 锚定
//! win(230,108) 宽 240。窗口 1280×668。
//!
//! HTML 语义对照：
//!  - .menu：rgba(248,255,251,.95) + blur(24) + 圆角 12 + 双层阴影，1px 边
//!    rgba(19,69,246,.1)，padding 5；
//!  - .mh2：头部两行（第一行混排加粗标题），下边线 rgba(0,0,0,.05)，margin-bottom 4；
//!  - .mi：高 29/32（文本行高实测 12.5px 行盒 15），padding 6 10、gap 9、
//!    圆角 8、icon 列宽 16、右注 sc 10.5 fg3；.mi.danger 红字；
//!  - .ms：1px 分隔线，margin 4 8，色 rgba(0,0,0,.06)。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 668 };
pub const title = "mockup-sidebar-context";

const tok = mock.tok;

// 菜单卡底色 rgba(248,255,251,.95)
const menu_bg = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242);
// 分隔线 rgba(0,0,0,.06)
const sep_col = ui.Color.rgba(0, 0, 0, 15);
// mh2 下边线 rgba(0,0,0,.05)
const mh2_line = ui.Color.rgba(0, 0, 0, 13);

fn txt(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .font_weight = weight, .color = color, .line_height = 1.2 });
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountMain(cx),
        try mountStatusBar(cx),
        try mountMenu(cx),
    });
}

// ── 标题栏（tbar 40px：红绿灯 + 2 页签 + 全局图标） ────────────────

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

    // 页签 ×2：K8s-Node01(on) / RDS-PG(off)
    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01 ✕", true));
    try bar.appendChild(cx.allocator, try tab(cx, "RDS-PG ✕", false));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));

    // 右侧全局图标：⚡ ⇅ ✨(acc) ⚙️
    try bar.appendChild(cx.allocator, try icn(cx, "⚡"));
    try bar.appendChild(cx.allocator, try icn(cx, "⇅"));
    try bar.appendChild(cx.allocator, try icn(cx, "✨"));
    try bar.appendChild(cx.allocator, try icn(cx, "⚙️"));
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
    try node.appendChild(cx.allocator, try txt(cx, name, 12, if (on) 500 else 400, if (on) tok.fg else tok.fg2));
    return node;
}

fn icn(cx: *ui.Cx, icon: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, icon, 14, 400, if (std.mem.eql(u8, icon, "✨")) tok.acc else tok.fg2));
    return node;
}

// ── 主体（main 600px：侧栏 224 + 终端区） ───────────────────────────

fn mountMain(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{
        try mountSidebar(cx),
        try mountTermPane(cx),
    });
}

fn mountSidebar(cx: *ui.Cx) !*ui.Node {
    const sb = try ui.box(cx, .{
        .width = .{ .px = 224 },
        .height = .fill(),
        .direction = .column,
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 8 },
        .flex_shrink = 0,
    }, .{});
    try sb.appendChild(cx.allocator, try groupHeader(cx, "生产环境"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "K8s-Node01", "via Bastion", true, true));
    try sb.appendChild(cx.allocator, try hostRow(cx, "K8s-Node02", null, true, false));
    try sb.appendChild(cx.allocator, try hostRow(cx, "RDS-PG", "2跳", false, false));
    try sb.appendChild(cx.allocator, try groupHeader(cx, "测试环境"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "Staging-App", null, false, false));
    return sb;
}

fn groupHeader(cx: *ui.Cx, name: []const u8) !*ui.Node {
    const gh = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 27 },
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try gh.appendChild(cx.allocator, try txt(cx, name, 10, 600, tok.fg3));
    return gh;
}

/// 主机行 .hr2：高 29（padding 7 + 文本行盒 15），gap 8，状态点 6，tag2 9px fg3。
fn hostRow(cx: *ui.Cx, name: []const u8, tag: ?[]const u8, online: bool, selected: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 29 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .background = if (selected) tok.alpha(tok.acc, 20) else ui.Color.TRANSPARENT,
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try mock.dot(cx, 6, if (online) tok.grn else tok.off_dot));
    try row.appendChild(cx.allocator, try txt(cx, name, 12.5, 400, tok.fg));
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    if (tag) |t| {
        try row.appendChild(cx.allocator, try txt(cx, t, 9, 400, tok.fg3));
    }
    return row;
}

fn mountTermPane(cx: *ui.Cx) !*ui.Node {
    const tp = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .overflow = .hidden,
    }, .{});
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .cursor = true }));
    return tp;
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
    try bar.appendChild(cx.allocator, try txt(cx, "侧栏主机右键菜单 · 复制/克隆 · 新Tab/新窗口连接 · 修改 · 查看历史", 11, 400, tok.fg2));
    return bar;
}

// ── 右键菜单浮层（.menu：win(230,108) 宽 240） ─────────────────────

fn mountMenu(cx: *ui.Cx) !*ui.Node {
    const menu = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 108 }, .left = .{ .px = 230 } },
        .z_index = 50,
        .width = .{ .px = 240 },
        .direction = .column,
        .padding = .{ .left = 5, .right = 5, .top = 5, .bottom = 5 },
        .background = menu_bg,
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 12 },
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36), .blur = 44, .offset_x = 0, .offset_y = 16 },
            .{ .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 15), .blur = 8, .offset_x = 0, .offset_y = 2 },
        }),
        .overflow = .hidden,
    }, .{});
    try menu.appendChild(cx.allocator, try menuHeader(cx));
    try menu.appendChild(cx.allocator, try mi(cx, 29, "▶", "新标签连接", "双击同效", false));
    // 🗔 (U+1F5D4) 在渲染环境无字形（参考 PNG 中该项图标区为空白），
    // 为匹配设计稿视觉效果用空格占位。
    try menu.appendChild(cx.allocator, try mi(cx, 29, " ", "新窗口连接", null, false));
    try menu.appendChild(cx.allocator, try msSep(cx));
    try menu.appendChild(cx.allocator, try mi(cx, 29, "⧉", "复制配置（克隆主机）", null, false));
    try menu.appendChild(cx.allocator, try mi(cx, 32, "✏️", "修改连接配置…", null, false));
    try menu.appendChild(cx.allocator, try mi(cx, 32, "📜", "查看历史会话日志", null, false));
    try menu.appendChild(cx.allocator, try mi(cx, 32, "📌", "置顶到分组首位", null, false));
    try menu.appendChild(cx.allocator, try msSep(cx));
    try menu.appendChild(cx.allocator, try mi(cx, 32, "📁", "移动分组 ▸", null, false));
    try menu.appendChild(cx.allocator, try mi(cx, 31, "🗑", "删除主机", null, true));
    return menu;
}

/// 菜单头部 .mh2：两行说明（第一行混排加粗标题），下边线 + margin-bottom 4。
fn menuHeader(cx: *ui.Cx) !*ui.Node {
    const h = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 43 },
        .direction = .column,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .border = .{ .width = 1, .color = mh2_line, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    const line1 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 19 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try line1.appendChild(cx.allocator, try txt(cx, "🖥 主机资产菜单", 10, 700, tok.fg3));
    try line1.appendChild(cx.allocator, try txt(cx, "（右键）· K8s-Node01", 10, 400, tok.fg3));
    try h.appendChild(cx.allocator, line1);
    const line2 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 11 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try line2.appendChild(cx.allocator, try txt(cx, "连接与配置管理 · 不含文本操作", 9, 400, tok.fg3));
    try h.appendChild(cx.allocator, line2);
    return h;
}

/// 菜单项 .mi：固定高 h，icon 列 16 + gap 9 + label 12.5，右注 sc 10.5 fg3。
fn mi(cx: *ui.Cx, h: f32, icon: []const u8, label: []const u8, sc: ?[]const u8, danger: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = h },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
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
        try row.appendChild(cx.allocator, try txt(cx, s, 10.5, 400, tok.fg3));
    }
    return row;
}

/// 分隔线 .ms：1px，margin 4 8。
fn msSep(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .margin = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 },
        .background = sep_col,
        .flex_shrink = 0,
    }, .{});
}
