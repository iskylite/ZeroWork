//! mockup-history-list — 历史会话列表设计稿复刻（docs/SPEC/html/mockup-history-list.html）。
//!
//! 结构：tbar(40) + main(560: sb 224 + pane 浮层) + sbar(28)。窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-history-list";

const tok = mock.tok;

const c_cyn = tok.cyn;
const c_line5 = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const c_card = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242); // rgba(248,255,251,.95)
const c_card_border = tok.alpha(tok.acc, 26); // rgba(19,69,246,.1)
const c_row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // #F2F9F4

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountMain(cx),
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
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 主体：侧栏 + 终端 pane（含历史浮层） ────────────────────────────

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
    // 分组标题
    const sg = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 5 },
    }, .{});
    try sg.appendChild(cx.allocator, try ui.text(cx, "生产环境", .{
        .font_size = 10, .font_weight = 600, .color = tok.fg3,
    }));
    try sb.appendChild(cx.allocator, sg);
    // 主机行 ×3
    try sb.appendChild(cx.allocator, try sidebarHost(cx, "K8s-Node01", true));
    try sb.appendChild(cx.allocator, try sidebarHost(cx, "DB-Master", true));
    try sb.appendChild(cx.allocator, try sidebarHost(cx, "RDS-PG", false));
    return sb;
}

fn sidebarHost(cx: *ui.Cx, name: []const u8, online: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 27 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
    }, .{});
    try row.appendChild(cx.allocator, try mock.dot(cx, 6, if (online) tok.grn else tok.off_dot));
    try row.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12.5, .color = tok.fg,
    }));
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
    // 唯一终端行：整行 cyan
    try pane.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu@k8s-node01:~$ ", .color = c_cyn },
    }, .{}));

    // ov：压暗层（flex-start + padding-top 48 / left 250）
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 1056 }, // pane 宽（1280-224）
        .height = .{ .px = 560 },
        .direction = .column,
        .align_items = .start,
        .background = ui.Color.rgba(0xEC, 0xFF, 0xF4, 115), // rgba(236,255,244,.45)
        .glass = .{ .backdrop_blur = 4 },
        .z_index = 10,
        .padding = .{ .left = 250, .right = 0, .top = 48, .bottom = 0 },
    }, .{});
    try ov.appendChild(cx.allocator, try mountHistoryCard(cx));
    try pane.appendChild(cx.allocator, ov);
    return pane;
}

// ── 历史会话卡（560 宽） ───────────────────────────────────────────

const Hist = struct {
    time: []const u8,
    host: []const u8,
    meta: []const u8,
    hot: bool,
};

const hists = [_]Hist{
    .{ .time = "今天 16:20", .host = "K8s-Node01", .meta = "2h 14m · exit 0 · 84 MB", .hot = true },
    .{ .time = "今天 11:03", .host = "DB-Master", .meta = "46m · exit 0 · 31 MB", .hot = false },
    .{ .time = "昨天 22:41", .host = "RDS-PG", .meta = "3h 02m · 断线结束 · 127 MB", .hot = false },
    .{ .time = "昨天 18:15", .host = "K8s-Node02", .meta = "12m · exit 1 · 9 MB", .hot = false },
};

fn mountHistoryCard(cx: *ui.Cx) !*ui.Node {
    const hl = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .direction = .column,
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) },
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 20,
        .overflow = .hidden,
    }, .{});

    // 头部
    const head = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 44 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 18, .right = 18, .top = 13, .bottom = 13 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "📜 历史会话 — K8s-Node01", .{
        .font_size = 13, .font_weight = 600, .color = tok.fg,
    }));
    try head.appendChild(cx.allocator, try ui.spacer(cx));
    try head.appendChild(cx.allocator, try ui.text(cx, "Tab 关闭不丢 · RawTap 落盘 · 回放为只读", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try hl.appendChild(cx.allocator, head);

    // 历史行 ×4
    for (hists) |h| {
        try hl.appendChild(cx.allocator, try historyRow(cx, h));
    }

    // 底注
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .padding = .{ .left = 18, .right = 18, .top = 9, .bottom = 9 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try foot.appendChild(cx.allocator, try ui.text(cx, "回放 = @log 时间轴模式（快进/拖动/搜索/复制）· 导出 txt / asciinema cast · 保留 30 天（设置-数据与日志可调）", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try hl.appendChild(cx.allocator, foot);
    return hl;
}

fn historyRow(cx: *ui.Cx, h: Hist) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 18, .right = 18, .top = 9, .bottom = 9 },
        .background = if (h.hot) tok.alpha(tok.acc, 10) else ui.Color.TRANSPARENT, // rgba(19,69,246,.04)
        .border = .{ .width = 1, .color = c_row_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 时间（86 宽）
    const t_col = try ui.box(cx, .{ .width = .{ .px = 86 }, .flex_shrink = 0 }, .{});
    try t_col.appendChild(cx.allocator, try ui.text(cx, h.time, .{
        .font_size = 10.5, .color = tok.fg2,
    }));
    try row.appendChild(cx.allocator, t_col);
    // 主机（100 宽 600）
    const h_col = try ui.box(cx, .{ .width = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    try h_col.appendChild(cx.allocator, try ui.text(cx, h.host, .{
        .font_size = 11.5, .font_weight = 600, .color = tok.fg,
    }));
    try row.appendChild(cx.allocator, h_col);
    // 元信息
    const m_col = try ui.box(cx, .{ .flex = 1, .min_width = 0 }, .{});
    try m_col.appendChild(cx.allocator, try ui.text(cx, h.meta, .{
        .font_size = 10.5, .color = tok.fg3,
    }));
    try row.appendChild(cx.allocator, m_col);
    // 操作
    const acts = try ui.box(cx, .{ .direction = .row, .gap = 8, .flex_shrink = 0 }, .{});
    try acts.appendChild(cx.allocator, try ui.text(cx, "▶ 回放", .{
        .font_size = 10.5, .font_weight = 500, .color = tok.acc,
    }));
    try acts.appendChild(cx.allocator, try ui.text(cx, "⤓ 导出", .{
        .font_size = 10.5, .color = tok.fg2,
    }));
    try row.appendChild(cx.allocator, acts);
    return row;
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "入口：侧栏主机右键「📜 查看历史会话日志」 · 或设置-数据与日志集中管理", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
