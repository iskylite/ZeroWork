//! mockup-settings-keys — 设置 · 快捷键页（docs/SPEC/html/mockup-settings-keys.html）。
//!
//! 结构：背板 1280×820 + 居中模态 860×700（Nav 190 无图标 + 内容区 + 底栏）。
//! 本页样式变体：nav-t 无底边框、.ni 无图标 gap 8、行无 padding（min-height 36）、
//! chip 高 26 mono、底部 note 信息条、按钮 height 34。
//! HTML .scroll 为 flex:1 overflow:auto（ftr 在滚动区外）——静态复刻呈现为
//! 内容区 flex 裁切 + 底栏固定贴底。所有尺寸/颜色逐条对照 HTML CSS。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 820 };
pub const title = "mockup-settings-keys";

const tok = mock.tok;

// ── 设置系局部 token ────────────────────────────────────────────────

const backdrop = ui.Color.rgb(0x4C, 0x4C, 0x4C);
const modal_bg = ui.Color.rgb(0xF7, 0xFF, 0xFB);
const nav_bg = tok.setnav;
const nav_bd = ui.Color.rgb(0xE4, 0xF1, 0xE8);
const row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // .row border-bottom
const chip_bg = ui.Color.rgb(0xF4, 0xFB, 0xF7);
const b2_bg = ui.Color.rgb(0xF4, 0xFB, 0xF7); // 本页 .b2 底色

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
        .width = .{ .px = 860 },
        .height = .{ .px = 700 },
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

// ── Nav（190px 无图标，on=快捷键；padding 18，acc.07·600） ──────────

fn mountNav(cx: *ui.Cx) !*ui.Node {
    const nav = try ui.box(cx, .{
        .width = .{ .px = 190 },
        .height = .fill(),
        .direction = .column,
        .background = nav_bg,
        .border = .{ .width = 1, .color = nav_bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .padding = .{ .left = 0, .right = 0, .top = 18, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});

    // 本页 nav-t 无 border-bottom：padding 0 18 14
    const nav_t = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 14 },
        .flex_shrink = 0,
    }, .{});
    try nav_t.appendChild(cx.allocator, try ui.text(cx, "设置", .{
        .font_size = 13,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    try nav.appendChild(cx.allocator, nav_t);

    const items = [_][]const u8{
        "外观与主题",
        "快捷键",
        "SSH 与网络",
        "文件传输",
        "AI 辅助",
        "协议插件",
        "通知",
        "数据与日志",
    };
    for (items, 0..) |label, i| {
        try nav.appendChild(cx.allocator, try navItem(cx, label, i == 1));
    }
    return nav;
}

fn navItem(cx: *ui.Cx, label: []const u8, on: bool) !*ui.Node {
    const ni = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 18, .right = 18, .top = 8, .bottom = 8 },
        .background = if (on) tok.alpha(tok.acc, 18) else ui.Color.TRANSPARENT, // rgba(19,69,246,.07)
        .border = if (on) .{ .width = 1, .color = tok.acc, .radius = 0, .side_widths = .{ -1, 2, -1, -1 } } else null,
        .flex_shrink = 0,
    }, .{});
    try ni.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .font_weight = if (on) 600 else 400,
        .color = if (on) tok.acc else tok.fg2,
        .line_height = 1.2,
    }));
    return ni;
}

// ── 内容区（快捷键） ────────────────────────────────────────────────

fn mountContent(cx: *ui.Cx) !*ui.Node {
    const col = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 22, .right = 22, .top = 16, .bottom = 12 },
        .overflow = .hidden,
        .min_width = 0,
        .flex_shrink = 0,
    }, .{});

    const t = try ui.box(cx, .{
        .width = .fill(),
        .flex_shrink = 0,
    }, .{});
    try t.appendChild(cx.allocator, try ui.text(cx, "快捷键", .{
        .font_size = 16,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.5,
    }));
    try col.appendChild(cx.allocator, t);
    const d = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 3, .bottom = 8 },
        .flex_shrink = 0,
    }, .{});
    try d.appendChild(cx.allocator, try ui.text(cx, "点击键位可重录。冲突显示红框。⌘ 归 App，⌃ 和 Tab 归远端。", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    try col.appendChild(cx.allocator, d);

    // .scroll：flex:1 + padding-right 4，溢出裁切（HTML overflow:auto 语义）。
    // col 内容高 672（700-16-12）减标题区 59.4 与 footer 44 → scroll 568 固定高。
    const scroll = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 568 },
        .direction = .column,
        .padding = .{ .left = 0, .right = 4, .top = 0, .bottom = 0 },
        .overflow = .hidden,
        .overflow_hidden = true,
        .flex_shrink = 0,
    }, .{});

    // ── 页签 ──
    try scroll.appendChild(cx.allocator, try secLabel(cx, "页签"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "新建 / 关闭", "关闭前若有传输、AI 写命令或 SOCKS，先确认", "⌘T / ⌘W"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "按序号直达", "窗口内第 1 到第 9 个页签", "⌘1 – ⌘9"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "上一个 / 下一个", "", "⌘⇧[ / ⌘⇧]"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "最近使用的页签", "按住切换，松开落定", "⌃⇥"));

    // ── 终端 ──
    try scroll.appendChild(cx.allocator, try secLabel(cx, "终端"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "分栏", "垂直 / 水平", "⌘D / ⌘⇧D"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "复制 / 粘贴", "⌘C 无选区时透传 SIGINT", "⌘C / ⌘V"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "搜索当前终端", "打开会话内搜索条", "⌘F"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "补全菜单 / 采纳", "Tab 永远送给远端 shell，不在这里采纳", "⌘; / →"));

    // ── 会话与工具 ──
    try scroll.appendChild(cx.allocator, try secLabel(cx, "会话与工具"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "快速连接 / 立即重连", "", "⌘K / ⌘R"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "侧栏 / AI 浮窗", "", "⌘B / ⌘J"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "上传面板 / 广播", "", "⌘U / ⌘⇧I"));

    // ── 鼠标（固定，不可改） ──
    try scroll.appendChild(cx.allocator, try secLabel(cx, "鼠标（固定，不可改）"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "页签", "右键菜单，中键直接关闭，双击改名", "右键 / 中键"));
    try scroll.appendChild(cx.allocator, try keyRow(cx, "终端", "右键：有选区复制，无选区粘贴。中键打开终端菜单", "右键 / 中键"));

    // .note 信息条
    const note = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 10, .bottom = 0 },
        .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 },
        .background = tok.alpha(tok.acc, 10), // rgba(19,69,246,.04)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try note.appendChild(cx.allocator, try ui.text(cx, "⌘K、⌘R 只改变 App 行为。远端清屏仍是 ⌃L，远端中断仍是 ⌃C。方向键、Tab、⌃ 组合全部原样送到当前会话。", .{
        .font_size = 10.5,
        .color = tok.fg2,
        .line_height = 1.55,
    }));
    try scroll.appendChild(cx.allocator, note);

    try col.appendChild(cx.allocator, scroll);
    // ftr 在滚动区外：固定贴底
    try col.appendChild(cx.allocator, try footer(cx));
    return col;
}

// ── 局部部件 ────────────────────────────────────────────────────────

/// .sec：10px·650 fg3，margin 10 0 4。
fn secLabel(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 10, .bottom = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10,
        .font_weight = 600,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    return node;
}

/// 快捷键行：min-height 36，无 padding，底分隔；右=mono chip。
fn keyRow(cx: *ui.Cx, row_title: []const u8, desc: []const u8, keys: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .min_height = 36,
        .border = .{ .width = 1, .color = row_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const rn = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .column,
        .min_width = 0,
    }, .{});
    try rn.appendChild(cx.allocator, try ui.text(cx, row_title, .{
        .font_size = 12.5,
        .font_weight = 500,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    if (desc.len > 0) {
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
    }
    try row.appendChild(cx.allocator, rn);
    try row.appendChild(cx.allocator, try chip(cx, keys));
    return row;
}

/// .chip：height 26 mono 11 padding 0 10 nowrap。
fn chip(cx: *ui.Cx, label: []const u8) !*ui.Node {
    return ui.box(cx, .{
        .height = .{ .px = 26 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = chip_bg,
        .border = .{ .width = 1, .color = tok.setbd, .radius = 7 },
        .flex_shrink = 0,
    }, .{
        try ui.text(cx, label, .{
            .font_size = 11,
            .color = tok.fg,
            .use_monospace_font = true,
            .line_height = 1.2,
        }),
    });
}

/// .ftr：gap 8 padding-top 10，无上边框（本页无 border-top）。
fn footer(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .gap = 8,
        .padding = .{ .left = 0, .right = 0, .top = 10, .bottom = 0 },
        .flex_shrink = 0,
    }, .{
        try btnSecondary(cx, "恢复默认"),
        try btnPrimary(cx, "保存设置"),
    });
}

/// .b1：height 34 padding 0 18 渐变 135°，白字 12·650→600。
fn btnPrimary(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
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

/// .b2：height 34 padding 0 14 底 #F4FBF7 边 1 --bd 字 12 fg2。
fn btnSecondary(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
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
