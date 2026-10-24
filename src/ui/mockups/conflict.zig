//! mockup-conflict — 同名冲突卡设计稿复刻（docs/SPEC/html/mockup-conflict.html）。
//!
//! 结构：tbar(40) + body(620，居中冲突卡 460 宽：本地/远端对照 + 四个纵向单选项
//! + 应用范围勾选 + 禁用态「继续」) + sbar(28)。窗口 1280×688。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 688 };
pub const title = "mockup-conflict";

const tok = mock.tok;

// HTML 内联色（:root token 之外的补充）
const files_bd = ui.Color.rgb(0xE7, 0xF3, 0xEC); // .files 边
const row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // .f+.f 上边线
const choice_bd = ui.Color.rgb(0xE4, 0xEF, 0xE8); // .choice 边
const dot_bd = ui.Color.rgb(0xC5, 0xD5, 0xCC); // .dot/.box 边
const cancel_bg = ui.Color.rgb(0xF4, 0xFB, 0xF7); // .b 底
const cont_bg = ui.Color.rgb(0xC9, 0xD4, 0xDE); // .bp 禁用底

fn txt(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color, line_h: f32) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .font_weight = weight, .color = color, .line_height = line_h });
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40px：红绿灯 + DB-Master 页签） ────────────────────

fn mountTitleBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const tls = try ui.box(cx, .{
        .direction = .row,
        .gap = 8,
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
    try tab.appendChild(cx.allocator, try txt(cx, "DB-Master ✕", 12, 500, tok.fg, 1.2));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 主体（body 620：压暗背板 + 冲突卡 460 居中） ────────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    const body = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 620 },
        .flex_shrink = 0,
    }, .{});
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .background = tok.alpha(tok.bg, 140), // rgba(236,255,244,.55)
        .glass = .{ .backdrop_blur = 6 },
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    try body.appendChild(cx.allocator, ov);
    return body;
}

fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 460 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 250), // rgba(248,255,251,.98)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 14 }, // rgba(19,69,246,.1)
        .shadow = .{ .blur = 60, .offset_y = 24, .color = ui.Color.rgba(15, 23, 42, 41) },
        .padding = .{ .left = 18, .right = 18, .top = 18, .bottom = 14 },
        .flex_shrink = 0,
    }, .{});

    // 标题 + 副说明
    const h = try ui.box(cx, .{ .width = .fill(), .flex_shrink = 0 }, .{});
    try h.appendChild(cx.allocator, try txt(cx, "app.tar.gz 已存在", 15, 650, tok.fg, 1.2));
    const sub = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .top = 4, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    try sub.appendChild(cx.allocator, try txt(cx, "远端 deploy/ 里已有同名文件。请选择怎么处理，选中前不能继续。不会默认覆盖。", 12, 400, tok.fg2, 1.45));
    try h.appendChild(cx.allocator, sub);
    try card.appendChild(cx.allocator, h);

    // 本地/远端对照表
    const files = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .top = 14, .right = 0, .bottom = 8, .left = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = files_bd, .radius = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try files.appendChild(cx.allocator, try frow(cx, "本地", "app.tar.gz", "48.1 MB · 刚刚", false));
    try files.appendChild(cx.allocator, try frow(cx, "远端", "deploy/app.tar.gz", "12.4 MB · 今天 09:12", true));
    try card.appendChild(cx.allocator, files);

    // 小节标题
    const sec = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .top = 12, .right = 0, .bottom = 6, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try sec.appendChild(cx.allocator, try txt(cx, "处理方式", 11, 650, tok.fg2, 1.2));
    try card.appendChild(cx.allocator, sec);

    // 四个纵向单选项（不预选）
    try card.appendChild(cx.allocator, try choice(cx, "跳过这个文件", "保留远端，继续队列里的下一个", false));
    try card.appendChild(cx.allocator, try choice(cx, "另存为 app-20261008-2051.tar.gz", "两边都留，新文件名自动带时间", false));
    try card.appendChild(cx.allocator, try choice(cx, "两边都保留，并打开对比", "不写入覆盖，传输完成后可再决定", false));
    try card.appendChild(cx.allocator, try choice(cx, "覆盖远端文件", "远端 12.4 MB 会被替换，不能撤销", true));

    // 应用范围勾选行
    const apply = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 8, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    const box = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .background = tok.white,
        .border = .{ .width = 1.5, .color = dot_bd, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try apply.appendChild(cx.allocator, box);
    try apply.appendChild(cx.allocator, try txt(cx, "本次剩余 6 个同名文件也按此处理", 12, 400, tok.fg2, 1.2));
    try card.appendChild(cx.allocator, apply);

    // 按钮行：取消 + 继续（禁用灰）
    const btns = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 14, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    const cancel = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 16, .right = 16, .top = 0, .bottom = 0 },
        .background = cancel_bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try cancel.appendChild(cx.allocator, try txt(cx, "取消", 12.5, 400, tok.fg2, 1.2));
    try btns.appendChild(cx.allocator, cancel);
    const cont = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .background = cont_bg,
        .border = .{ .width = 0, .color = cont_bg, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try cont.appendChild(cx.allocator, try txt(cx, "继续", 12.5, 650, tok.white, 1.2));
    try btns.appendChild(cx.allocator, cont);
    try card.appendChild(cx.allocator, btns);
    return card;
}

// ── 对照行（grid 52px 1fr auto → row 近似） ────────────────────────

fn frow(cx: *ui.Cx, tag: []const u8, name: []const u8, meta: []const u8, sep: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .background = tok.white,
        .border = if (sep) .{ .width = 1, .color = row_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } } else null,
        .flex_shrink = 0,
    }, .{});
    const tag_node = try ui.box(cx, .{ .width = .{ .px = 52 }, .flex_shrink = 0 }, .{});
    try tag_node.appendChild(cx.allocator, try txt(cx, tag, 10, 650, tok.fg3, 1.2));
    try row.appendChild(cx.allocator, tag_node);
    const name_node = try ui.box(cx, .{ .flex = 1, .min_width = 0 }, .{});
    try name_node.appendChild(cx.allocator, try txt(cx, name, 12.5, 600, tok.fg, 1.2));
    try row.appendChild(cx.allocator, name_node);
    const meta_node = try ui.box(cx, .{ .flex_shrink = 0 }, .{});
    try meta_node.appendChild(cx.allocator, try txt(cx, meta, 11, 400, tok.fg3, 1.2));
    try row.appendChild(cx.allocator, meta_node);
    return row;
}

// ── 单选项（grid 16px 1fr + 双行文本 → row + 内嵌 column） ──────────

fn choice(cx: *ui.Cx, head: []const u8, desc: []const u8, danger: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 12, .right = 12, .top = 9, .bottom = 9 },
        .background = tok.white,
        .border = .{ .width = 1, .color = choice_bd, .radius = 10 },
        .margin = .{ .top = 0, .right = 0, .bottom = 6, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    // 空心单选圆点 15×15（不预选）
    const dot_node = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .background = tok.white,
        .border = .{ .width = 1.5, .color = dot_bd, .radius = 7.5 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, dot_node);
    const texts = try ui.box(cx, .{ .direction = .column, .flex = 1, .min_width = 0 }, .{});
    try texts.appendChild(cx.allocator, try txt(cx, head, 12.5, 600, if (danger) tok.red else tok.fg, 1.2));
    const desc_node = try ui.box(cx, .{
        .margin = .{ .top = 2, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    try desc_node.appendChild(cx.allocator, try txt(cx, desc, 11, 400, tok.fg3, 1.35));
    try texts.appendChild(cx.allocator, desc_node);
    try node.appendChild(cx.allocator, texts);
    return node;
}

// ── 状态栏（sbar 28px，无状态点） ──────────────────────────────────

fn mountStatusBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .background = tok.stbg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try txt(cx, "未选择前「继续」不可用 · 覆盖单独放在最后，并用危险色 · 不预选任何一项", 11, 400, tok.fg2, 1.2));
    return bar;
}
