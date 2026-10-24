//! mockup-socks5-entry — SOCKS5 入口设计稿复刻（docs/SPEC/html/mockup-socks5-entry.html）。
//!
//! 结构：tbar(40) + main(560: sb 224 + pane) + sbar(28) + 主机资产菜单(absolute)。
//! 窗口 1280×628。菜单 left190 top150 为 .win 坐标（含 tbar 40）。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-socks5-entry";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_card = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242); // rgba(248,255,251,.95)
const c_card_border = tok.alpha(tok.acc, 26); // rgba(19,69,246,.1)
const c_line5 = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const c_ms = ui.Color.rgba(0, 0, 0, 15); // rgba(0,0,0,.06)
const c_note_bg = ui.Color.rgb(0x0F, 0x17, 0x2A); // #0F172A

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountMain(cx),
        try mountStatusBar(cx),
    });
    // 主机资产菜单（.win 坐标 absolute，置顶）
    try root.appendChild(cx.allocator, try mountAssetMenu(cx));
    return root;
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
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 主体：侧栏 + 终端 pane ─────────────────────────────────────────

fn mountMain(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{
        try mountSidebar(cx),
        try mountPane(cx),
    });
}

fn mountSidebar(cx: *ui.Cx) !*ui.Node {
    const sb = try ui.box(cx, .{
        .width = .{ .px = 224 },
        .height = .fill(),
        .direction = .column,
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try sb.appendChild(cx.allocator, try groupTitle(cx, "生产环境"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "K8s-Node01", true, null));
    try sb.appendChild(cx.allocator, try hostRow(cx, "DB-Master", true, "🧦:1080 后台"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "RDS-PG", false, null));
    try sb.appendChild(cx.allocator, try groupTitle(cx, "测试环境"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "Staging-App", false, null));
    return sb;
}

fn groupTitle(cx: *ui.Cx, name: []const u8) !*ui.Node {
    const sg = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 5 },
    }, .{});
    try sg.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 10, .font_weight = 600, .color = tok.fg3,
    }));
    return sg;
}

fn hostRow(cx: *ui.Cx, name: []const u8, online: bool, sk_badge: ?[]const u8) !*ui.Node {
    // html .hr2 无固定高：padding 7×2 + 17.5 行高 ≈ 31.5
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 31.5 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
    }, .{});
    try row.appendChild(cx.allocator, try mock.dot(cx, 6, if (online) tok.grn else tok.off_dot));
    try row.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12.5, .color = tok.fg,
    }));
    if (sk_badge) |b| {
        try row.appendChild(cx.allocator, try ui.spacer(cx));
        const badge = try ui.box(cx, .{
            .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
            .background = tok.alpha(tok.acc, 20), // rgba(19,69,246,.08)
            .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
        }, .{});
        try badge.appendChild(cx.allocator, try ui.text(cx, b, .{
            .font_size = 9, .font_weight = 600, .color = tok.acc,
        }));
        try row.appendChild(cx.allocator, badge);
    }
    return row;
}

fn mountPane(cx: *ui.Cx) !*ui.Node {
    const pane = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 0 },
        .overflow = .hidden,
    }, .{});
    // 光标行：png 中无 .input 高亮（普通行 + 块光标）
    try pane.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = " ", .color = tok.fg },
    }, .{ .cursor = true }));

    // 4 条编号注解（absolute left 480 top 200/228/276/304）
    try pane.appendChild(cx.allocator, try note(cx, "① 已开会话：@socks on 即时开（复用当前连接，无需重连）", 200));
    try pane.appendChild(cx.allocator, try note(cx, "② Tab 右键菜单同样入口；信息卡可改配置并写回", 228));
    try pane.appendChild(cx.allocator, try note(cx, "③ 侧栏右键「仅开启转发」= 后台转发会话（无 Tab）", 276));
    try pane.appendChild(cx.allocator, try note(cx, "④ 未配置主机同样可用——配置非前置条件", 304));
    return pane;
}

/// 深色编号注解（10px 白字，#0F172A 底，圆角 6）。
fn note(cx: *ui.Cx, text: []const u8, top: f32) !*ui.Node {
    const n = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = top }, .left = .{ .px = 480 } },
        .height = .{ .px = 22 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
        .background = c_note_bg,
        .border = .{ .width = 0, .color = c_note_bg, .radius = 6 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = ui.Color.rgba(0, 0, 0, 64) }, // rgba(0,0,0,.25)
        .z_index = 60,
    }, .{});
    try n.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 10, .color = tok.white,
    }));
    return n;
}

// ── 主机资产菜单（.win 坐标 left190 top150，宽 250） ────────────────

fn mountAssetMenu(cx: *ui.Cx) !*ui.Node {
    const menu = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 150 }, .left = .{ .px = 190 } },
        .width = .{ .px = 250 },
        .direction = .column,
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) },
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 50,
        .padding = .{ .left = 5, .right = 5, .top = 5, .bottom = 5 },
    }, .{});

    // 头部
    const head = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "🖥 主机资产菜单", .{
        .font_size = 10, .font_weight = 700, .color = tok.fg3,
    }));
    try head.appendChild(cx.allocator, try ui.text(cx, "（右键）· DB-Master", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try menu.appendChild(cx.allocator, head);

    // 条目
    try menu.appendChild(cx.allocator, try menuRow(cx, "▶", "新标签连接", null, false));
    try menu.appendChild(cx.allocator, try menuRow(cx, "🧦", "仅开启 SOCKS5 转发", "不开终端", true));
    try menu.appendChild(cx.allocator, try menuRow(cx, "🧦", "连接并开启转发", null, false));
    try menu.appendChild(cx.allocator, try menuSeparator(cx));
    try menu.appendChild(cx.allocator, try menuRow(cx, "⧉", "复制配置（克隆主机）", null, false));
    try menu.appendChild(cx.allocator, try menuRow(cx, "✏️", "修改连接配置…", null, false));
    try menu.appendChild(cx.allocator, try menuRow(cx, "📜", "查看历史会话日志", null, false));
    try menu.appendChild(cx.allocator, try menuSeparator(cx));
    try menu.appendChild(cx.allocator, try menuRow(cx, "🗑", "删除主机", null, false));
    return menu;
}

/// 菜单分隔线（1px，内缩 8，色 rgba(0,0,0,.06)）。
fn menuSeparator(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .margin = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 },
        .background = c_ms,
        .flex_shrink = 0,
    }, .{});
}

/// 菜单条目：ic(16) + 标签 + 右注；hot=accent.07；红字项。
fn menuRow(cx: *ui.Cx, icon: []const u8, label: []const u8, hint: ?[]const u8, hot: bool) !*ui.Node {
    const danger = std.mem.eql(u8, icon, "🗑");
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = if (hot) tok.alpha(tok.acc, 18) else ui.Color.TRANSPARENT,
        .border = .{ .width = 0, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 16 },
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 12, .color = if (danger) tok.red else tok.fg2,
    }));
    try row.appendChild(cx.allocator, ic);
    try row.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5, .color = if (danger) tok.red else tok.fg,
    }));
    if (hint) |h| {
        try row.appendChild(cx.allocator, try ui.spacer(cx));
        try row.appendChild(cx.allocator, try ui.text(cx, h, .{
            .font_size = 9.5, .color = tok.fg3,
        }));
    }
    return row;
}

// ── 状态栏：k8s-node01 + 🧦 后台转发 ×1 ────────────────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "k8s-node01", .{
        .font_size = 11, .color = tok.fg2,
    }));
    // "|" 分隔（margin 0 4，色 bd）
    const sep = try ui.box(cx, .{
        .margin = .{ .top = 0, .right = 4, .bottom = 0, .left = 4 },
    }, .{});
    try sep.appendChild(cx.allocator, try ui.text(cx, "|", .{
        .font_size = 11, .color = tok.bd,
    }));
    try bar.appendChild(cx.allocator, sep);
    try bar.appendChild(cx.allocator, try ui.text(cx, "🧦 后台转发 ×1（DB-Master :1080）", .{
        .font_size = 11, .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "后台转发会话：有认证无 PTY，不占 Tab，重连自动恢复", .{
        .font_size = 10, .color = tok.fg3,
    }));
    return bar;
}
