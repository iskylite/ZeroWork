//! mockup-theme-picker — 会话主题浮条设计稿复刻（docs/SPEC/html/mockup-theme-picker.html）。
//!
//! 结构：tbar(40) + term(560, pk 浮条 absolute left250 top8) + sbar(28)。窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-theme-picker";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_line5 = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const c_card = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242); // rgba(248,255,251,.95)
const c_card_border = tok.alpha(tok.acc, 26); // rgba(19,69,246,.1)
const c_dark_tab_dot = ui.Color.rgb(0x1E, 0x1E, 0x2E); // tab2 色点

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏：K8s-Node01(on) + 生产-DB(带主题色点) ────────────────────

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

    // tab1：K8s-Node01（.tab = on 样式：bg+500+阴影+1px ring）
    const tab1 = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab1.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab1);

    // tab2：生产-DB（已覆盖主题）+ 8px 深色点
    const tab2 = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    const tab2_dot = try ui.box(cx, .{
        .width = .{ .px = 8 },
        .height = .{ .px = 8 },
        .background = c_dark_tab_dot,
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 38), .radius = 4 }, // rgba(0,0,0,.15)
        .flex_shrink = 0,
    }, .{});
    try tab2.appendChild(cx.allocator, tab2_dot);
    try tab2.appendChild(cx.allocator, try ui.text(cx, "生产-DB（已覆盖主题）✕", .{
        .font_size = 12, .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, tab2);

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区 + 主题浮条 ──────────────────────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    // 输入行（高亮 + 光标）：png 中高亮为 fit-content（到块光标右缘止），
    // common.termLine 的 input 是整行填充，这里本地实现 fit 版本。
    const input_row = try ui.box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 15),
        .border = .{ .width = 0, .color = tok.acc, .radius = 3 },
        .flex_shrink = 0,
    }, .{});
    try input_row.appendChild(cx.allocator, try ui.text(cx, "ubuntu", .{ .font_size = 13, .color = tok.cyn, .use_monospace_font = true, .line_height = 1.5 }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "@k8s-node01:", .{ .font_size = 13, .color = tok.fg, .use_monospace_font = true, .line_height = 1.5 }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "~", .{ .font_size = 13, .color = c_tb, .use_monospace_font = true, .line_height = 1.5 }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "$ ", .{ .font_size = 13, .color = tok.fg, .use_monospace_font = true, .line_height = 1.5 }));
    try input_row.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 8 },
        .height = .{ .px = 16 },
        .background = tok.fg,
        .flex_shrink = 0,
    }, .{}));
    try term.appendChild(cx.allocator, input_row);

    // 主题浮条（pk：absolute left 250 top 8 width 400）
    try term.appendChild(cx.allocator, try mountThemePicker(cx));
    return term;
}

const Theme = struct {
    dot: ui.Color,
    name: []const u8,
    follow: bool,
    on: bool = false, // .tr.on 选中底 rgba(19,69,246,.07)
    sw: [4]ui.Color,
};

const themes = [_]Theme{
    .{ .dot = ui.Color.rgb(0xEC, 0xFF, 0xF4), .name = "Sauber Light（全局默认）", .follow = true, .on = true,
        .sw = .{ ui.Color.rgb(0x0F, 0x17, 0x2A), tok.acc, tok.grn, tok.red } },
    .{ .dot = ui.Color.rgb(0x1E, 0x1E, 0x2E), .name = "Dark Pro", .follow = false,
        .sw = .{ ui.Color.rgb(0xCD, 0xD6, 0xF4), ui.Color.rgb(0x89, 0xB4, 0xFA), ui.Color.rgb(0xA6, 0xE3, 0xA1), ui.Color.rgb(0xF3, 0x8B, 0xA8) } },
    .{ .dot = ui.Color.rgb(0x00, 0x2B, 0x36), .name = "Solarized Dark", .follow = false,
        .sw = .{ ui.Color.rgb(0x83, 0x94, 0x96), ui.Color.rgb(0x26, 0x8B, 0xD2), ui.Color.rgb(0x2A, 0xA1, 0x98), ui.Color.rgb(0xDC, 0x32, 0x2F) } },
    .{ .dot = ui.Color.rgb(0x28, 0x2A, 0x36), .name = "Dracula", .follow = false,
        .sw = .{ ui.Color.rgb(0xF8, 0xF8, 0xF2), ui.Color.rgb(0xBD, 0x93, 0xF9), ui.Color.rgb(0x50, 0xFA, 0x7B), ui.Color.rgb(0xFF, 0x55, 0x55) } },
    .{ .dot = ui.Color.rgb(0x1A, 0x0B, 0x0B), .name = "生产警示·红", .follow = false,
        .sw = .{ ui.Color.rgb(0xF5, 0xD0, 0xD0), ui.Color.rgb(0xFF, 0x6B, 0x6B), ui.Color.rgb(0xFF, 0xD9, 0x3D), ui.Color.rgb(0xFF, 0x9F, 0x43) } },
};

fn mountThemePicker(cx: *ui.Cx) !*ui.Node {
    const pk = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 8 }, .left = .{ .px = 250 } },
        .width = .{ .px = 400 },
        .direction = .column,
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) }, // 0 16 44 rgba(15,23,42,.14)
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 50,
        .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 },
    }, .{});

    // 指示箭头（::after：12² 旋转 45°，left 63 top -6）
    const arrow = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = -6 }, .left = .{ .px = 63 } },
        .width = .{ .px = 12 },
        .height = .{ .px = 12 },
        .background = c_card,
        .border = .{ .width = 1, .color = c_card_border, .radius = 0, .side_widths = .{ 1, -1, -1, 1 } }, // left+top
        .rotate = 0.785398, // 45°
    }, .{});
    try pk.appendChild(cx.allocator, arrow);

    // 头部说明（11 fg3，自然换行 2 行）
    const head = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 8 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "🎨 会话主题 — 仅当前会话终端区生效 · Tab 右键 / @theme / 连接配置预设 / 设置全局", .{
        .font_size = 11, .color = tok.fg3, .line_height = 1.55, .wrap = .word,
    }));
    try pk.appendChild(cx.allocator, head);

    // 5 主题行
    for (themes) |t| {
        try pk.appendChild(cx.allocator, try themeRow(cx, t));
    }

    // 底注（9.5 fg3，自然换行）
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .padding = .{ .left = 8, .right = 8, .top = 7, .bottom = 2 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .margin = .{ .top = 4, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    try foot.appendChild(cx.allocator, try ui.text(cx, "覆盖范围：终端区 16 色/背景/选区/光标 · 窗口框架仍跟随全局 · 已覆盖会话 Tab 带色点", .{
        .font_size = 9.5, .color = tok.fg3, .wrap = .word,
    }));
    try pk.appendChild(cx.allocator, foot);
    return pk;
}

/// 主题行：dot(14) + 名称(+跟随全局) + 右 4 色卡。行高 32（padding 7×2 + 18）。
fn themeRow(cx: *ui.Cx, t: Theme) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 8, .right = 8, .top = 0, .bottom = 0 },
        .background = if (t.on) tok.alpha(tok.acc, 18) else ui.Color.rgba(0, 0, 0, 0), // .tr.on rgba(19,69,246,.07)
        .border = .{ .width = 0, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    const dot = try ui.box(cx, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
        .background = t.dot,
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 31), .radius = 7 }, // rgba(0,0,0,.12)
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, dot);
    try row.appendChild(cx.allocator, try ui.text(cx, t.name, .{
        .font_size = 12, .font_weight = 500, .color = tok.fg,
    }));
    if (t.follow) {
        const ck = try ui.box(cx, .{
            .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 8 },
        }, .{});
        try ck.appendChild(cx.allocator, try ui.text(cx, "✓ 跟随全局", .{
            .font_size = 9.5, .font_weight = 600, .color = tok.acc,
        }));
        try row.appendChild(cx.allocator, ck);
    }
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    // swatch：4×10² 圆角 3，gap 3
    const sw = try ui.box(cx, .{ .direction = .row, .gap = 3, .flex_shrink = 0 }, .{});
    for (t.sw) |c| {
        try sw.appendChild(cx.allocator, try ui.box(cx, .{
            .width = .{ .px = 10 },
            .height = .{ .px = 10 },
            .background = c,
            .border = .{ .width = 0, .color = c, .radius = 3 },
        }, .{}));
    }
    try row.appendChild(cx.allocator, sw);
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "会话级主题：四入口（Tab 菜单 / @theme / 主机配置 theme 字段 / 设置全局）· 覆盖仅终端区", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
