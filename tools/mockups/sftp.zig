//! mockup-sftp — 传输管理器右贴边浮卡设计稿复刻（docs/SPEC/html/mockup-sftp.html）。
//!
//! HTML 语义对照：设计稿命名 sftp，实际内容是 .tpanel 传输管理器下拉（宽 480，
//! 锚 tbar 右下 top 46 / right 14）+ 3 个任务行 + 底部统计行（含 spark 图）。
//! SPEC §4 描述「SFTP 面板 330 宽 + 路径 chip」与 html 不符，以 html 为准。
//! 结构：tbar(40) + term(600，.tpanel 绝对锚定) + sbar(28)。窗口 1280×668。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 668 };
pub const title = "mockup-sftp";

const tok = mock.tok;

// HTML 内联色（:root token 之外的补充）
const f1f5f9 = ui.Color.rgb(0xF1, 0xF5, 0xF9); // .tp-h 下边线 / .tabtn 底 / .ti-bar 底
const f8fafc = ui.Color.rgb(0xF8, 0xFA, 0xFC); // .ti 行间分隔
const grn2 = ui.Color.rgb(0x34, 0xD3, 0x99); // 进度条渐变终点

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
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40px：红绿灯 + 2 页签 + 全局图标，⇅ 高亮带徽标 3）──

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
        .z_index = 60,
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

    // 页签 ×2：K8s-Node01(on) / DB-Master(off)
    const t1 = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try t1.appendChild(cx.allocator, try txt(cx, "K8s-Node01 ✕", 12, 500, tok.fg));
    try bar.appendChild(cx.allocator, t1);
    const t2 = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try t2.appendChild(cx.allocator, try txt(cx, "DB-Master ✕", 12, 400, tok.fg2));
    try bar.appendChild(cx.allocator, t2);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));

    try bar.appendChild(cx.allocator, try icn(cx, "⚡", false, false));
    try bar.appendChild(cx.allocator, try icn(cx, "⇅", true, true));
    try bar.appendChild(cx.allocator, try icn(cx, "✨", false, true));
    try bar.appendChild(cx.allocator, try icn(cx, "⚙️", false, false));
    return bar;
}

fn icn(cx: *ui.Cx, icon: []const u8, hl: bool, acc: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try txt(cx, icon, 14, 400, if (acc) tok.acc else if (hl) tok.acc else tok.fg2));
    if (hl) {
        // ⇅ 高亮底 + 徽标 3
        const bdg = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .top = .{ .px = 1 }, .right = .{ .px = 0 } },
            .height = .{ .px = 13 },
            .min_width = 13,
            .direction = .row,
            .align_items = .center,
            .justify = .center,
            .padding = .{ .left = 3, .right = 3, .top = 0, .bottom = 0 },
            .background = tok.grn,
            .border = .{ .width = 0, .color = tok.grn, .radius = 7 },
        }, .{});
        try bdg.appendChild(cx.allocator, try txt(cx, "3", 8.5, 600, tok.white));
        try node.appendChild(cx.allocator, bdg);
    }
    return node;
}

// ── 终端区（.tpanel 绝对锚定 top 46 / right 14） ────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{});
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ @dl /var/log/syslog.1", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] SFTP 下载已加入队列: syslog.1 → ~/Downloads/ (经 Bastion-01 隧道)", .color = tdim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .cursor = true }));
    try term.appendChild(cx.allocator, try mountTPanel(cx));
    return term;
}

// ── 传输管理器浮卡（.tpanel 480 宽右贴边） ─────────────────────────

fn mountTPanel(cx: *ui.Cx) !*ui.Node {
    const panel = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 46 }, .right = .{ .px = 14 } },
        .width = .{ .px = 480 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 247), // rgba(248,255,251,.97)
        .glass = .{ .backdrop_blur = 30 },
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 13), .radius = 13 }, // .5px≈1
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(0, 0, 0, 51), .blur = 50, .offset_x = 0, .offset_y = 20 },
            .{ .color = ui.Color.rgba(0, 0, 0, 20), .blur = 0, .offset_x = 0, .offset_y = 0 },
        }),
        .z_index = 50,
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});

    // 头部：⇅ 传输管理器 · ● 聚合 18.9 MB/s
    const head = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 },
        .border = .{ .width = 1, .color = f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try txt(cx, "⇅", 14, 400, tok.fg));
    try head.appendChild(cx.allocator, try txt(cx, "传输管理器", 13, 600, tok.fg));
    try head.appendChild(cx.allocator, try ui.spacer(cx));
    const st = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 }, .{});
    try st.appendChild(cx.allocator, try mock.dot(cx, 6, tok.grn));
    try st.appendChild(cx.allocator, try txt(cx, "聚合 18.9 MB/s", 10.5, 500, tok.grn));
    try head.appendChild(cx.allocator, st);
    try panel.appendChild(cx.allocator, head);

    // 列表（.tp-list padding 6 0）
    const list = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 0, .right = 0, .top = 6, .bottom = 6 },
        .flex_shrink = 0,
    }, .{});
    try list.appendChild(cx.allocator, try ti(cx, .up, "release-v2.4.0-arm64.tar.gz", "→ /opt/deploy/ · 经 2 跳隧道 · SFTP 窗口 16", "12.4 MB/s", "68% · 剩 2s", 68, false, false, &.{ "⏸", "✕" }, tok.fg, false));
    try list.appendChild(cx.allocator, try ti(cx, .up, "config-backup-20261008.zip", "→ /etc/nginx/ · 直连 · 断点续传自 41%", "6.5 MB/s", "52% · 剩 8s", 52, false, false, &.{ "⏸", "✕" }, tok.fg, false));
    try list.appendChild(cx.allocator, try ti(cx, .dl, "syslog.1", "← /var/log/ · 经 Bastion-01 · @dl 指令触发", "排队中", "#3", 0, false, false, &.{ "▲", "✕" }, tok.fg, false));
    try list.appendChild(cx.allocator, try ti(cx, .ok, "dump-1008.sql.gz", "← /backup/ · 182 MB · MD5 校验通过", "已完成", "14:21 · 31.2 MB/s", 100, false, true, &.{"↗"}, tok.grn, true));
    try panel.appendChild(cx.allocator, list);

    // 底部统计行 + spark 图
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 14, .right = 14, .top = 9, .bottom = 9 },
        .border = .{ .width = 1, .color = f1f5f9, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try foot.appendChild(cx.allocator, try txt(cx, "并发窗口: 16×64KB", 10.5, 400, tok.fg3));
    try foot.appendChild(cx.allocator, try txt(cx, "队列: 3", 10.5, 400, tok.fg3));
    try foot.appendChild(cx.allocator, try txt(cx, "今日: 1.2 GB", 10.5, 400, tok.fg3));
    const spark = try ui.box(cx, .{
        .direction = .row,
        .align_items = .end,
        .gap = 2,
        .height = .{ .px = 22 },
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 10 },
        .flex_shrink = 0,
    }, .{});
    for ([_]f32{ 30, 45, 60, 50, 75, 90, 100, 85 }) |h| {
        const spk = try ui.box(cx, .{
            .width = .{ .px = 4 },
            .height = .{ .px = 22 * h / 100 },
            .background = tok.grn,
            .border = .{ .width = 0, .color = tok.grn, .radius = 1.5 },
            .opacity = 0.75,
            .flex_shrink = 0,
        }, .{});
        try spark.appendChild(cx.allocator, spk);
    }
    try foot.appendChild(cx.allocator, try ui.spacer(cx));
    try foot.appendChild(cx.allocator, spark);
    try panel.appendChild(cx.allocator, foot);
    return panel;
}

const TiKind = enum { up, dl, ok };

fn ti(
    cx: *ui.Cx,
    kind: TiKind,
    name: []const u8,
    meta: []const u8,
    speed: []const u8,
    eta: []const u8,
    pct: f32,
    _: bool,
    done: bool,
    acts: []const []const u8,
    speed_color: ui.Color,
    dim: bool,
) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 16, .right = 16, .top = 9, .bottom = 9 },
        .border = if (done) null else .{ .width = 1, .color = f8fafc, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .opacity = if (dim) 0.75 else 1.0,
        .flex_shrink = 0,
    }, .{});

    const r1 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 9,
    }, .{});
    // 图标 26²
    const ic = try ui.box(cx, .{
        .width = .{ .px = 26 },
        .height = .{ .px = 26 },
        .align_items = .center,
        .justify = .center,
        .background = if (kind == .up) tok.alpha(tok.acc, 18) else if (kind == .dl) tok.alpha(tok.cyn, 20) else tok.alpha(tok.grn, 20),
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try txt(cx, if (kind == .up) "⬆" else if (kind == .dl) "⬇" else "✓", 13, 400, if (kind == .up) tok.acc else if (kind == .dl) tok.cyn else tok.grn));
    try r1.appendChild(cx.allocator, ic);

    // 名称 + 元信息
    const mid = try ui.box(cx, .{ .direction = .column, .flex = 1, .min_width = 0 }, .{});
    try mid.appendChild(cx.allocator, try txt(cx, name, 12.5, 500, tok.fg));
    const mt = try ui.box(cx, .{
        .margin = .{ .top = 1, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    try mt.appendChild(cx.allocator, try mono(cx, meta, 10, 400, tok.fg2));
    try mid.appendChild(cx.allocator, mt);
    try r1.appendChild(cx.allocator, mid);

    // 右侧：速度 + ETA（右对齐）
    const rt = try ui.box(cx, .{ .direction = .column, .align_items = .end, .flex_shrink = 0 }, .{});
    try rt.appendChild(cx.allocator, try txt(cx, speed, 11, 600, speed_color));
    const eta_box = try ui.box(cx, .{
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    try eta_box.appendChild(cx.allocator, try txt(cx, eta, 10, 400, tok.fg2));
    try rt.appendChild(cx.allocator, eta_box);
    try r1.appendChild(cx.allocator, rt);

    // 操作按钮组
    const act_row = try ui.box(cx, .{
        .direction = .row,
        .gap = 5,
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 8 },
        .flex_shrink = 0,
    }, .{});
    for (acts) |a| {
        const btn = try ui.box(cx, .{
            .width = .{ .px = 20 },
            .height = .{ .px = 20 },
            .align_items = .center,
            .justify = .center,
            .background = f1f5f9,
            .border = .{ .width = 0, .color = f1f5f9, .radius = 5 },
            .flex_shrink = 0,
        }, .{});
        try btn.appendChild(cx.allocator, try txt(cx, a, 9, 400, tok.fg2));
        try act_row.appendChild(cx.allocator, btn);
    }
    try r1.appendChild(cx.allocator, act_row);
    try row.appendChild(cx.allocator, r1);

    // 进度条（已完成行无 bar；排队行画空轨道）
    if (!done) {
        const bar = try ui.box(cx, .{
            .width = .fill(),
            .height = .{ .px = 4 },
            .margin = .{ .top = 7, .right = 0, .bottom = 0, .left = 0 },
            .background = f1f5f9,
            .border = .{ .width = 0, .color = f1f5f9, .radius = 2 },
            .overflow = .hidden,
            .flex_shrink = 0,
        }, .{});
        // 可用宽 = 480 - 2*16 = 448；pct=0 时空轨道
        if (pct > 0) {
            const fill = try ui.box(cx, .{
                .width = .{ .px = 448 * pct / 100 },
                .height = .fill(),
                .gradient = .{ .from = tok.grn, .to = grn2, .direction = .horizontal },
                .border = .{ .width = 0, .color = tok.grn, .radius = 2 },
            }, .{});
            try bar.appendChild(cx.allocator, fill);
        }
        try row.appendChild(cx.allocator, bar);
    }
    return row;
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
    try bar.appendChild(cx.allocator, try txt(cx, "已连接  |  ⇅ 2 个传输进行中", 11, 400, tok.fg2));
    return bar;
}
