//! mockup-quickconnect — 设计稿静态复刻（docs/SPEC/html/mockup-quickconnect.html）。
//!
//! ⌘K 顶挂 520×?? 快速连接面板（实际 CSS 宽 620）：输入行 + 匹配主机 +
//! 最近连接 + 底部快捷键行。窗口 1280×700（.win 高）。
//!
//! 结构：tbar(40) + bodyc(flex，rgba(15,23,42,.28)+blur4 压暗底) +
//! palette(absolute，top 90 / left 330 / 620 宽 / 高 316)。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 700 };
pub const title = "mockup-quickconnect";

const tok = mock.tok;

// HTML 内非 token 色（局部常量）
const c_f1f5f9 = ui.Color.rgb(0xF1, 0xF5, 0xF9); // #F1F5F9 分隔线/芯片底
const c_e2e8f0 = ui.Color.rgb(0xE2, 0xE8, 0xF0); // #E2E8F0 芯片边
const c_b45309 = ui.Color.rgb(0xB4, 0x53, 0x09); // Staging 徽标字色

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
    });
}

// ── 标题栏（tbar 40：红绿灯 + 单个未激活页签） ─────────────────────

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

    // 红绿灯组：12px 圆，gap 8，右缘 10（与预览程序原生红绿灯重叠）。
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

    // 单个未激活页签：K8s-Node01 ✕（无底无描边）
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12,
        .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 主体（bodyc：压暗底 + 顶挂 palette） ───────────────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    const body = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .background = ui.Color.rgba(15, 23, 42, 71), // rgba(15,23,42,.28) over --bg
        // HTML 的 blur(4px) 在纯色底上是 no-op，不加 glass 以免引入暗色 veil。
        .flex_shrink = 0,
    }, .{});
    try body.appendChild(cx.allocator, try mountPalette(cx));
    return body;
}

fn mountPalette(cx: *ui.Cx) !*ui.Node {
    // margin-top:90 → 距 bodyc 顶 90（窗口顶 40+90=130）；水平居中 330。
    const pal = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 90 }, .left = .{ .px = 330 } },
        .width = .{ .px = 620 },
        .direction = .column,
        .background = ui.Color.rgba(248, 255, 251, 247), // rgba(248,255,251,.97)
        // HTML 的 blur(30px) 在纯色底上是 no-op，不加 glass 以免引入 veil。
        .border = .{ .width = 0, .color = tok.white, .radius = 14 },
        .shadow = .{ .blur = 60, .offset_y = 24, .color = ui.Color.rgba(0, 0, 0, 71) },
        .overflow = .hidden,
    }, .{});

    // 输入行 .pi：高 51，⚡ + "k8s" + ⌘K 芯片
    const pi = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 51 },
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try pi.appendChild(cx.allocator, try ui.text(cx, "⚡", .{ .font_size = 16, .color = tok.fg3 }));
    try pi.appendChild(cx.allocator, try ui.text(cx, "k8s", .{ .font_size = 15.5, .color = tok.fg }));
    try pi.appendChild(cx.allocator, try ui.spacer(cx));
    try pi.appendChild(cx.allocator, try kbdChip(cx, "⌘K", 5));
    try pal.appendChild(cx.allocator, pi);

    // 匹配主机
    try pal.appendChild(cx.allocator, try psec(cx, "匹配主机"));
    try pal.appendChild(cx.allocator, try hostRow(cx, true, "K8s-", "Node01", "ubuntu@10.200.1.18 · via Bastion-01", "🟢", tok.alpha(tok.grn, 26), "Production", tok.red, null, null));
    try pal.appendChild(cx.allocator, try hostRow(cx, false, "K8s-", "Node02", "ubuntu@10.200.1.19 · via Bastion-01", "🟢", tok.alpha(tok.grn, 26), "Production", tok.red, null, null));
    try pal.appendChild(cx.allocator, try hostRow(cx, false, "Staging-", "K8s", "deploy@172.16.0.30 · Direct", "⚪", c_f1f5f9, "Staging", c_b45309, null, null));

    // 最近连接
    try pal.appendChild(cx.allocator, try psec(cx, "最近连接"));
    try pal.appendChild(cx.allocator, try hostRow(cx, false, "Bastion-01", "", "ops_jumper@118.31.22.10:2222", "🕐", c_f1f5f9, null, null, null, "2 分钟前"));

    try pal.appendChild(cx.allocator, try mountFooter(cx));
    return pal;
}

/// 分节标题 .psec：高 21，字 10.5·600 fg3，左内缩 8。
fn psec(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const s = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 21 },
        .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try s.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .font_weight = 600,
        .color = tok.fg3,
    }));
    return s;
}

/// 快捷键芯片 .kbd：底 #F1F5F9 边 #E2E8F0 圆角 r，字 10.5 fg3。
fn kbdChip(cx: *ui.Cx, label: []const u8, radius: f32) !*ui.Node {
    const chip = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 3, .bottom = 3 },
        .background = c_f1f5f9,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = radius },
        .flex_shrink = 0,
    }, .{});
    try chip.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    return chip;
}

/// 快捷键芯片 .kbd2（pfoot 内）：padding 1×6，圆角 4，mono 字。
fn kbdChip2(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const chip = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
        .background = c_f1f5f9,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try chip.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .color = tok.fg3,
        .use_monospace_font = true,
    }));
    return chip;
}

/// 结果行 .pr：高 47，图标 26² 圆角7 + 名称/元信息 + 分组徽标 + 右注。
fn hostRow(
    cx: *ui.Cx,
    sel: bool,
    name_prefix: []const u8,
    name_bold: []const u8,
    meta: []const u8,
    icon: []const u8,
    icon_bg: ui.Color,
    grp_label: ?[]const u8,
    grp_color: ?ui.Color,
    right_note: ?[]const u8,
    time_note: ?[]const u8,
) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 47 },
        .direction = .row,
        .align_items = .center,
        .gap = 11,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .background = if (sel) tok.alpha(tok.acc, 15) else ui.Color.TRANSPARENT, // rgba(19,69,246,.06)
        .flex_shrink = 0,
    }, .{});

    // 图标位 .ic：26×26 圆角 7
    const ic = try ui.box(cx, .{
        .width = .{ .px = 26 },
        .height = .{ .px = 26 },
        .align_items = .center,
        .justify = .center,
        .background = icon_bg,
        .border = .{ .width = 0, .color = icon_bg, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 13 }));
    try row.appendChild(cx.allocator, ic);

    // 名称 + 元信息两行
    const labels = try ui.box(cx, .{ .direction = .column }, .{});
    const nm = try ui.box(cx, .{ .direction = .row }, .{});
    try nm.appendChild(cx.allocator, try ui.text(cx, name_prefix, .{
        .font_size = 13,
        .font_weight = 500,
        .color = tok.fg,
    }));
    if (name_bold.len > 0) {
        try nm.appendChild(cx.allocator, try ui.text(cx, name_bold, .{
            .font_size = 13,
            .font_weight = 700,
            .color = tok.fg,
        }));
    }
    try labels.appendChild(cx.allocator, nm);
    try labels.appendChild(cx.allocator, try ui.text(cx, meta, .{
        .font_size = 11,
        .color = tok.fg2,
        .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, labels);

    // 分组徽标 .grp
    if (grp_label) |gl| {
        const grp = try ui.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .padding = .{ .left = 7, .right = 7, .top = 2, .bottom = 2 },
            .background = tok.alpha(grp_color.?, 20), // .08 ≈ 20/255
            .border = .{ .width = 0, .color = grp_color.?, .radius = 4 },
            .flex_shrink = 0,
        }, .{});
        try grp.appendChild(cx.allocator, try ui.text(cx, gl, .{
            .font_size = 10,
            .font_weight = 500,
            .color = grp_color.?,
        }));
        try row.appendChild(cx.allocator, grp);
    }

    try row.appendChild(cx.allocator, try ui.spacer(cx));

    // 右注 .rt：选中行 "↵ 连接"（acc·500·11），其余 "↵"/时间（10.5 fg3）
    if (sel) {
        try row.appendChild(cx.allocator, try ui.text(cx, "↵ 连接", .{
            .font_size = 11,
            .font_weight = 500,
            .color = tok.acc,
        }));
    } else if (right_note) |rn| {
        try row.appendChild(cx.allocator, try ui.text(cx, rn, .{
            .font_size = 10.5,
            .color = tok.fg3,
        }));
    }
    if (time_note) |tn| {
        try row.appendChild(cx.allocator, try ui.text(cx, tn, .{
            .font_size = 10.5,
            .color = tok.fg3,
        }));
    }
    return row;
}

/// 底部快捷键行 .pfoot：高 35，上边线 #F1F5F9。
fn mountFooter(cx: *ui.Cx) !*ui.Node {
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 35 },
        .direction = .row,
        .align_items = .center,
        .gap = 14,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try foot.appendChild(cx.allocator, try footItem(cx, "↑↓", "选择"));
    try foot.appendChild(cx.allocator, try footItem(cx, "↵", "连接"));
    try foot.appendChild(cx.allocator, try footItem(cx, "⌘↵", "在新分栏打开"));
    try foot.appendChild(cx.allocator, try ui.spacer(cx));
    // 或输入 user@host:port 即兴直连
    try foot.appendChild(cx.allocator, try ui.text(cx, "或输入", .{ .font_size = 10.5, .color = tok.fg3 }));
    try foot.appendChild(cx.allocator, try kbdChip2(cx, "user@host:port"));
    try foot.appendChild(cx.allocator, try ui.text(cx, "即兴直连", .{ .font_size = 10.5, .color = tok.fg3 }));
    return foot;
}

fn footItem(cx: *ui.Cx, key: []const u8, label: []const u8) !*ui.Node {
    const item = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 3,
        .flex_shrink = 0,
    }, .{});
    try item.appendChild(cx.allocator, try kbdChip2(cx, key));
    try item.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    return item;
}
