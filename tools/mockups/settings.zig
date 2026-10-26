//! mockup-settings — 设置 · 外观与主题页（docs/SPEC/html/mockup-settings.html）。
//!
//! 结构：背板 1280×720（rgba(0,0,0,.25) 叠 #666 = #4C4C4C）+ 居中模态 840×600
//! （Nav 190 + 内容区 + 底栏按钮；内容自然溢出由 overflow:hidden 裁切，与设计稿一致）。
//! 所有尺寸/颜色逐条对照 HTML CSS。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 720 };
pub const title = "mockup-settings";

const tok = mock.tok;

// ── 设置系局部 token（:root 与局部样式对照） ─────────────────────────

const backdrop = ui.Color.rgb(0x4C, 0x4C, 0x4C); // rgba(0,0,0,.25) over #666
const modal_bg = ui.Color.rgb(0xF7, 0xFF, 0xFB); // .md
const nav_bg = tok.setnav; // #EFF9F2
const nav_bd = ui.Color.rgb(0xE4, 0xF1, 0xE8); // .nav border-right
const nav_t_sep = ui.Color.rgb(0xF1, 0xF5, 0xF9); // .nav-t border-bottom
const row_sep = ui.Color.rgb(0xF6, 0xF9, 0xF7); // .row border-bottom
const chip_bg = ui.Color.rgb(0xF4, 0xFB, 0xF7); // .chip 背景
const b2_bg = ui.Color.rgb(0xF1, 0xF5, 0xF9); // .b2 背景
const ftr_sep = ui.Color.rgb(0xF1, 0xF5, 0xF9); // .ftr border-top
const q_bg = ui.Color.rgb(0xEE, 0xF3, 0xF0); // .rn .q 背景
const grn_txt = ui.Color.rgb(0x05, 0x96, 0x69); // #059669 徽标字色

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

// ── Nav（190px，8 项带图标） ────────────────────────────────────────

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

    // .nav-t「⚙ 设置」13px·700，padding 0 20 16，下分隔 1px + margin-bottom 8
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
        try nav.appendChild(cx.allocator, try navItem(cx, it.icon, it.label, i == 0));
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
        .background = if (on) tok.alpha(tok.acc, 15) else ui.Color.TRANSPARENT, // rgba(19,69,246,.06)
        .border = if (on) .{ .width = 1, .color = tok.acc, .radius = 0, .side_widths = .{ -1, 2, -1, -1 } } else null,
        .flex_shrink = 0,
    }, .{});
    // .ic 图标列：宽 20，字 14
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

// ── 内容区（外观与主题） ────────────────────────────────────────────

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

    // 页标题 + 描述
    const t = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 3 },
        .flex_shrink = 0,
    }, .{});
    try t.appendChild(cx.allocator, try ui.text(cx, "外观与主题", .{
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
    try d.appendChild(cx.allocator, try ui.text(cx, "主题与字体排版，写入 config.toml [ui]，支持导入 .itermcolors", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, d);

    // ── 主题：三张主题卡 ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "主题"));
    const grid = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .gap = 10,
        .margin = .{ .left = 0, .right = 0, .top = 4, .bottom = 6 },
        .flex_shrink = 0,
    }, .{});
    try grid.appendChild(cx.allocator, try themeCard(cx, "Sauber（默认）", true, .{
        .bg = ui.Color.rgb(0xEC, 0xFF, 0xF4),
        .fg = ui.Color.rgb(0x0F, 0x17, 0x2A),
        .dollar = tok.grn,
        .name = ui.Color.rgb(0x06, 0xB6, 0xD4),
        .status = tok.grn,
    }));
    try grid.appendChild(cx.allocator, try themeCard(cx, "Catppuccin Mocha", false, .{
        .bg = ui.Color.rgb(0x1E, 0x1E, 0x2E),
        .fg = ui.Color.rgb(0xCD, 0xD6, 0xF4),
        .dollar = ui.Color.rgb(0xA6, 0xE3, 0xA1),
        .name = ui.Color.rgb(0x89, 0xB4, 0xFA),
        .status = ui.Color.rgb(0xA6, 0xE3, 0xA1),
    }));
    try grid.appendChild(cx.allocator, try themeCard(cx, "Dracula", false, .{
        .bg = ui.Color.rgb(0x28, 0x2A, 0x36),
        .fg = ui.Color.rgb(0xF8, 0xF8, 0xF2),
        .dollar = ui.Color.rgb(0x50, 0xFA, 0x7B),
        .name = ui.Color.rgb(0x8B, 0xE9, 0xFD),
        .status = ui.Color.rgb(0x50, 0xFA, 0x7B),
    }));
    try ct.appendChild(cx.allocator, grid);

    // ＋ 导入 .itermcolors 主题…（右对齐）
    const imp = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 2 },
        .flex_shrink = 0,
    }, .{});
    try imp.appendChild(cx.allocator, try ui.text(cx, "＋ 导入 .itermcolors 主题…", .{
        .font_size = 11,
        .color = tok.acc,
        .line_height = 1.2,
    }));
    try ct.appendChild(cx.allocator, imp);

    // ── 字体与排版 ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "字体与排版"));
    try ct.appendChild(cx.allocator, try settingRow(cx, "字体族", "等宽字体，支持连字 Ligatures", false, try ctlSingle(cx, try chipS(cx, "JetBrains Mono", true, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "字体大小", "⌘+ / ⌘- 可在终端内动态调整", false, try ctlSingle(cx, try chipS(cx, "14 pt", false, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "基准字重", "SGR bold 自动升一级字重渲染（真实变体，非合成加粗）", true, try weightGroup(cx)));
    try ct.appendChild(cx.allocator, try settingRow(cx, "行间距", "字符行间像素间距倍率", false, try ctlSingle(cx, try chipS(cx, "1.5", false, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "光标样式", "方块 / 竖线 / 下划线", false, try ctlSingle(cx, try chipS(cx, "█ Block", false, true))));

    // ── 终端辅助显示 ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "终端辅助显示"));
    try ct.appendChild(cx.allocator, try settingRow(cx, "时间戳侧栏", "左列 gutter，与命令对齐、不参与复制；@ts 可临时开关", false, try ctlSingle(cx, try mock.toggle(cx, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "App 级命令补全", "ghost-text 本地预测，Tab 永远送给远端；采纳用右方向键；⌘; 开全量菜单", true, try ctlSingle(cx, try mock.toggle(cx, true))));
    try ct.appendChild(cx.allocator, try settingRow(cx, "输入行相对高亮", "当前命令行整行淡色 + 左缘竖条，滚动后一眼定位输入位置（终端增强）", false, try ctlSingle(cx, try mock.toggle(cx, true))));

    // ── 底栏（超出可视区，由 overflow 裁切，与设计稿一致） ──
    try ct.appendChild(cx.allocator, try footer(cx));
    return ct;
}

// ── 局部部件 ────────────────────────────────────────────────────────

/// .sec 小节标：10.5·600·fg3，margin 16 0 2。
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

/// .row 设置行：min-h 38，padding 8 0，下分隔 1px；左=名称(12.5·500)+描述(10·fg3)，右=控件。
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

/// 右侧控件容器（.ctl）。
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

/// ⓘ 圆：13²，底 #EEF3F0，"?" 9px fg3。
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

/// .chip：高 26 / 圆角 7 / 边 1px --bd / 底 #F4FBF7 / 字 11.5（mono 11）/ min-w 96 居中；has-drop 后缀 " ▾"。
fn chipS(cx: *ui.Cx, label: []const u8, mono_font: bool, drop: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .fit = .{ .min = 96, .max = std.math.inf(f32) } },
        .height = .{ .px = 26 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
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

/// 基准字重按钮组：Light / Regular(on) / Medium / Bold。
fn weightGroup(cx: *ui.Cx) !*ui.Node {
    const grp = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .flex_shrink = 0,
    }, .{});
    try grp.appendChild(cx.allocator, try ech(cx, "Light", false));
    try grp.appendChild(cx.allocator, try ech(cx, "Regular", true));
    try grp.appendChild(cx.allocator, try ech(cx, "Medium", false));
    try grp.appendChild(cx.allocator, try ech(cx, "Bold", false));
    return grp;
}

/// .echip：padding 4 10，10.5px；on=acc.08 底+acc 边+acc 字 600。
fn ech(cx: *ui.Cx, label: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
        .background = if (on) tok.alpha(tok.acc, 20) else ui.Color.TRANSPARENT,
        .border = .{ .width = 1, .color = if (on) tok.acc else tok.setbd, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .font_weight = if (on) 600 else 400,
        .color = if (on) tok.acc else tok.fg3,
        .line_height = 1.2,
    }));
    return node;
}

/// 主题卡：2px 边（选中 accent + 3px ring），上=终端预览两行，下=名称条。
fn themeCard(cx: *ui.Cx, name: []const u8, sel: bool, pal: struct {
    bg: ui.Color,
    fg: ui.Color,
    dollar: ui.Color,
    name: ui.Color,
    status: ui.Color,
}) !*ui.Node {
    const card = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .column,
        .background = tok.white,
        .border = .{ .width = 2, .color = if (sel) tok.acc else tok.setbd, .radius = 10 },
        .shadow = if (sel) .{ .blur = 0, .offset_y = 0, .spread = 3, .color = tok.alpha(tok.acc, 31) } else null,
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});

    // 终端预览：padding 8 10，mono 9 lh1.6，两行
    const prev = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 },
        .background = pal.bg,
        .flex_shrink = 0,
    }, .{});
    const l1 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try l1.appendChild(cx.allocator, try ui.text(cx, "$", .{ .font_size = 9, .color = pal.dollar, .use_monospace_font = true, .line_height = 1.6 }));
    try l1.appendChild(cx.allocator, try ui.text(cx, " kubectl get pods", .{ .font_size = 9, .color = pal.fg, .use_monospace_font = true, .line_height = 1.6 }));
    try prev.appendChild(cx.allocator, l1);
    const l2 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try l2.appendChild(cx.allocator, try ui.text(cx, "NAME", .{ .font_size = 9, .color = pal.name, .use_monospace_font = true, .line_height = 1.6 }));
    try l2.appendChild(cx.allocator, try ui.text(cx, " READY ", .{ .font_size = 9, .color = pal.fg, .use_monospace_font = true, .line_height = 1.6 }));
    try l2.appendChild(cx.allocator, try ui.text(cx, "STATUS", .{ .font_size = 9, .color = pal.status, .use_monospace_font = true, .line_height = 1.6 }));
    try prev.appendChild(cx.allocator, l2);
    try card.appendChild(cx.allocator, prev);

    // 名称条：白底、上分隔、space-between（选中卡带 ✓ 当前 徽标）
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .background = tok.white,
        .border = .{ .width = 1, .color = nav_t_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 10.5,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    if (sel) {
        const b = try ui.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .padding = .{ .left = 7, .right = 7, .top = 1, .bottom = 1 },
            .background = tok.alpha(tok.grn, 26),
            .border = .{ .width = 0, .color = tok.grn, .radius = 4 },
            .flex_shrink = 0,
        }, .{});
        try b.appendChild(cx.allocator, try ui.text(cx, "✓ 当前", .{
            .font_size = 9,
            .font_weight = 600,
            .color = grn_txt,
            .line_height = 1.2,
        }));
        try bar.appendChild(cx.allocator, b);
    }
    try card.appendChild(cx.allocator, bar);
    return card;
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

/// .b1 主按钮：padding 8 20，渐变 135° #1345F6→#2563EB，白字 12·600。
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

/// .b2 次按钮：padding 8 16，底 #F1F5F9，边 1px --bd，字 12 fg2。
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
