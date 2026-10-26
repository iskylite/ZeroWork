//! mockup-settings-notify — 设置 · 通知页（docs/SPEC/html/mockup-settings-notify.html）。
//!
//! 结构：背板 1280×720 + 居中模态 840×600（Nav 190 + 内容区 + 底栏）。
//! 所有尺寸/颜色逐条对照 HTML CSS。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 720 };
pub const title = "mockup-settings-notify";

const tok = mock.tok;

// ── 设置系局部 token ────────────────────────────────────────────────

const backdrop = ui.Color.rgb(0x4C, 0x4C, 0x4C);
const modal_bg = ui.Color.rgb(0xF7, 0xFF, 0xFB);
const nav_bg = tok.setnav;
const nav_bd = ui.Color.rgb(0xE4, 0xF1, 0xE8);
const nav_t_sep = ui.Color.rgb(0xF1, 0xF5, 0xF9);
const row_sep = ui.Color.rgb(0xF6, 0xF9, 0xF7);
const chip_bg = ui.Color.rgb(0xF4, 0xFB, 0xF7);
const b2_bg = ui.Color.rgb(0xF1, 0xF5, 0xF9);
const ftr_sep = ui.Color.rgb(0xF1, 0xF5, 0xF9);
const q_bg = ui.Color.rgb(0xEE, 0xF3, 0xF0);

// ── 模态框架 ────────────────────────────────────────────────────────

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .background = backdrop,
        .overflow = .hidden,
    }, .{});
    const md = try ui.box(cx, .{
        .width = .{ .px = 840 },
        .height = .{ .px = 600 },
        .direction = .row,
        .background = modal_bg,
        .border = .{ .width = 0, .color = modal_bg, .radius = 14 },
        .shadow = .{ .blur = 70, .offset_y = 30, .color = ui.Color.rgba(0, 0, 0, 64) },
        .overflow = .hidden,
        .overflow_hidden = true,
        .flex_shrink = 0,
    }, .{
        try mountNav(cx),
        try mountContent(cx),
    });
    try root.appendChild(cx.allocator, md);
    return root;
}

// ── Nav（190px，on=通知） ───────────────────────────────────────────

fn mountNav(cx: *ui.Cx) !*ui.Node {
    const nav = try ui.box(cx, .{
        .width = .{ .px = 190 },
        .height = .fill(),
        .direction = .column,
        .background = nav_bg,
        .border = .{ .width = 1, .color = nav_bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .padding = .{ .left = 0, .right = 0, .top = 20, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});

    const nav_t = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 20, .right = 20, .top = 0, .bottom = 16 },
        .border = .{ .width = 1, .color = nav_t_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 8 },
        .flex_shrink = 0,
    }, .{});
    try nav_t.appendChild(cx.allocator, try ui.text(cx, "⚙ 设置", .{
        .font_size = 13,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    try nav.appendChild(cx.allocator, nav_t);

    const items = [_]struct { icon: []const u8, label: []const u8 }{
        .{ .icon = "🎨", .label = "外观与主题" },
        .{ .icon = "⌨️", .label = "快捷键" },
        .{ .icon = "🔗", .label = "SSH 与网络" },
        .{ .icon = "📁", .label = "文件传输" },
        .{ .icon = "✨", .label = "AI 辅助" },
        .{ .icon = "🧩", .label = "协议插件" },
        .{ .icon = "🔔", .label = "通知" },
        .{ .icon = "💾", .label = "数据与日志" },
    };
    for (items, 0..) |it, i| {
        try nav.appendChild(cx.allocator, try navItem(cx, it.icon, it.label, i == 6));
    }
    return nav;
}

fn navItem(cx: *ui.Cx, icon: []const u8, label: []const u8, on: bool) !*ui.Node {
    const ni = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 8 },
        .background = if (on) tok.alpha(tok.acc, 15) else ui.Color.TRANSPARENT,
        .border = if (on) .{ .width = 1, .color = tok.acc, .radius = 0, .side_widths = .{ -1, 2, -1, -1 } } else null,
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 20 },
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 14, .color = if (on) tok.acc else tok.fg2 }));
    try ni.appendChild(cx.allocator, ic);
    try ni.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.acc else tok.fg2,
        .line_height = 1.2,
    }));
    return ni;
}

// ── 内容区（通知） ──────────────────────────────────────────────────

fn mountContent(cx: *ui.Cx) !*ui.Node {
    const ct = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 28, .right = 28, .top = 20, .bottom = 0 },
        .overflow = .hidden,
        .overflow_hidden = true,
        .flex_shrink = 0,
    }, .{});

    const t = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 3 },
        .flex_shrink = 0,
    }, .{});
    try t.appendChild(cx.allocator, try ui.text(cx, "通知", .{
        .font_size = 16,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, t);
    const d = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 14 },
        .flex_shrink = 0,
    }, .{});
    try d.appendChild(cx.allocator, try ui.text(cx, "系统通知与提醒（macOS 通知中心）", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, d);

    // ── 事件通知 ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "事件通知"));
    try ct.appendChild(cx.allocator, try settingRow(cx, "传输完成", "SFTP 上传/下载结束（含 MD5 校验结果）", false, try ctlSingle(cx, try mock.toggle(cx, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "断线与重连", "自动重连成功 / 最终失败时提醒", false, try ctlSingle(cx, try mock.toggle(cx, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "AI 诊断就绪", "浮窗收起状态下结论完成时提醒", false, try ctlSingle(cx, try mock.toggle(cx, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "终端 Bell", "远端 BEL 字符 → 系统提示音", false, try ctlSingle(cx, try mock.toggle(cx, false))));

    // ── 免打扰 ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "免打扰"));
    try ct.appendChild(cx.allocator, try settingRow(cx, "非活跃标签圆点", "后台会话有新输出时 Tab 显示圆点（非系统通知）", false, try ctlSingle(cx, try mock.toggle(cx, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "勿扰时段", "时段内仅静默入库，不弹横幅", false, try ctlSingle(cx, try chip(cx, "22:00 – 08:00", false, true))));

    // ── 底栏 ──
    try ct.appendChild(cx.allocator, try footer(cx));
    return ct;
}

// ── 局部部件 ────────────────────────────────────────────────────────

fn secLabel(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 16, .bottom = 2 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .font_weight = 600,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    return node;
}

fn settingRow(cx: *ui.Cx, row_title: []const u8, desc: []const u8, info: bool, control: *ui.Node) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .min_height = 38,
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 0 },
        .border = .{ .width = 1, .color = row_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const rn = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .column,
        .min_width = 0,
    }, .{});
    const tl = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 5,
        .flex_shrink = 0,
    }, .{});
    try tl.appendChild(cx.allocator, try ui.text(cx, row_title, .{
        .font_size = 12.5,
        .font_weight = 500,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    if (info) try tl.appendChild(cx.allocator, try qmark(cx));
    try rn.appendChild(cx.allocator, tl);
    const dl = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 1, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try dl.appendChild(cx.allocator, try ui.text(cx, desc, .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.4,
    }));
    try rn.appendChild(cx.allocator, dl);
    try row.appendChild(cx.allocator, rn);
    try row.appendChild(cx.allocator, control);
    return row;
}

fn ctlSingle(cx: *ui.Cx, child: *ui.Node) !*ui.Node {
    const ctl = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    try ctl.appendChild(cx.allocator, child);
    return ctl;
}

fn qmark(cx: *ui.Cx) !*ui.Node {
    const q = try ui.box(cx, .{
        .width = .{ .px = 13 },
        .height = .{ .px = 13 },
        .align_items = .center,
        .justify = .center,
        .background = q_bg,
        .border = .{ .width = 0, .color = q_bg, .radius = 6.5 },
        .flex_shrink = 0,
    }, .{});
    try q.appendChild(cx.allocator, try ui.text(cx, "?", .{
        .font_size = 9,
        .color = tok.fg3,
        .line_height = 1.2,
    }));
    return q;
}

/// .chip：min-w 96 居中，has-drop 加 " ▾"。
fn chip(cx: *ui.Cx, label: []const u8, mono_font: bool, drop: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .fit = .{ .min = 96, .max = std.math.inf(f32) } },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
        .background = chip_bg,
        .border = .{ .width = 1, .color = tok.setbd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = if (mono_font) 11 else 11.5,
        .color = tok.fg,
        .use_monospace_font = mono_font,
        .line_height = 1.2,
    }));
    if (drop) {
        try node.appendChild(cx.allocator, try ui.text(cx, " ▾", .{
            .font_size = 11.5,
            .color = tok.fg3,
            .line_height = 1.2,
        }));
    }
    return node;
}

/// .ftr 底栏：右对齐 [恢复默认][保存设置]。
fn footer(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 12, .bottom = 0 },
        .border = .{ .width = 1, .color = ftr_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .margin = .{ .left = 0, .right = 0, .top = 12, .bottom = 0 },
        .flex_shrink = 0,
    }, .{
        try btnSecondary(cx, "恢复默认"),
        try btnPrimary(cx, "保存设置"),
    });
}

fn btnPrimary(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 8 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.white,
        .line_height = 1.5,
    }));
    return node;
}

fn btnSecondary(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
        .background = b2_bg,
        .border = .{ .width = 1, .color = tok.setbd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .color = tok.fg2,
        .line_height = 1.5,
    }));
    return node;
}
