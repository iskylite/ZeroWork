//! mockup-term-context — 终端右键菜单（docs/SPEC/html/mockup-term-context.html）。
//!
//! 结构：tbar(40) + term(600) + sbar(28)。总高 668。
//!  - .term 13px/1.5，padding 10 14，相对定位；
//!  - .hl 选区高亮条：absolute left 250 top 78，340×20 acc.18 圆角 3；
//!  - .input 输入行：acc.06 底 + 左缘 3px accent 内阴影 + 圆角 3；
//!  - .menu：absolute top 92 left 250 宽 250，rgba(248,255,251,.95)+blur24
//!    saturate1.2，radius 12，双层阴影，边 acc.10，padding 5；
//!  - .mh2 头部 2 行（10px fg3，下边线 rgba(0,0,0,.05)，margin-bottom 4）；
//!  - .mi 项：padding 6 10、gap 9、圆角 8、icon 16 列、sc 右注 10.5 fg3；
//!    danger 红（本稿无 danger 项）；.ms 分隔线 1px margin 4 8。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 668 };
pub const title = "mockup-term-context";

const tok = mock.tok;

/// HTML 内联色：菜单容器/项与 tab-context 同族。
const menu_bd = ui.Color.rgba(19, 69, 246, 26); // rgba(19,69,246,.1)
const note = tok.fg3;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerminal(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（页签 ×2 + 右侧图标，无 mm 胶囊） ───────────────────────

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

    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01 ✕", true));
    try bar.appendChild(cx.allocator, try tab(cx, "RDS-PG ✕", false));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    for ([_][]const u8{ "⚡", "⇅", "✨", "⚙️" }) |icon| {
        const icn = try ui.box(cx, .{
            .width = .{ .px = 30 },
            .height = .{ .px = 28 },
            .align_items = .center,
            .justify = .center,
            .flex_shrink = 0,
        }, .{});
        try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
            .font_size = 14,
            .color = if (std.mem.eql(u8, icon, "✨")) tok.acc else tok.fg2,
        }));
        try bar.appendChild(cx.allocator, icn);
    }
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    return ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    })});
}

// ── 终端区（4 行 + 选区高亮条 + 输入行 + 菜单浮层） ─────────────────

fn mountTerminal(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .position = .relative,
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    const td = tok.alpha(tok.fg, 140); // .td opacity .55
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl logs backend-api-7b89f6d --tail=5", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "2026-10-08T14:20:01Z INFO request handled status=200", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "2026-10-08T14:20:03Z ERROR upstream timeout after 30s", .color = td },
    }, .{}));
    // .input 输入行（共享 termLine 的 input 语义：acc.06 + 左 3px accent）
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = " ", .color = tok.fg },
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));

    // .hl 选区高亮条：absolute left 250-14(padding)=236? —— HTML 的 left 是
    // 相对 .term 定位（含 padding 盒），直接用 250/78。
    const hl = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 78 }, .left = .{ .px = 250 } },
        .width = .{ .px = 340 },
        .height = .{ .px = 20 },
        .background = tok.alpha(tok.acc, 46), // .18
        .border = .{ .width = 0, .color = tok.acc, .radius = 3 },
        .z_index = 5,
    }, .{});
    try term.appendChild(cx.allocator, hl);

    try term.appendChild(cx.allocator, try mountMenu(cx));
    return term;
}

/// .menu：top 92 / left 250 / 宽 250。
fn mountMenu(cx: *ui.Cx) !*ui.Node {
    const menu = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 92 }, .left = .{ .px = 250 } },
        .z_index = 50,
        .width = .{ .px = 250 },
        .direction = .column,
        .padding = .{ .left = 5, .right = 5, .top = 5, .bottom = 5 },
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242), // .95
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = menu_bd, .radius = 12 },
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36), .blur = 44, .offset_x = 0, .offset_y = 16 },
            .{ .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 15), .blur = 8, .offset_x = 0, .offset_y = 2 },
        }),
        .overflow = .hidden,
    }, .{});
    // .mh2 头部两行
    const header = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 13), .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try header.appendChild(cx.allocator, try ui.text(cx, "📝 终端菜单 · 文本与视图操作（中键打开）", .{
        .font_size = 10,
        .font_weight = 700,
        .color = note,
        .line_height = 1.5,
    }));
    try header.appendChild(cx.allocator, try ui.text(cx, "右键=有选区复制/无选区粘贴 · 与页签/侧栏菜单零重叠", .{
        .font_size = 10,
        .color = note,
        .line_height = 1.5,
    }));
    try menu.appendChild(cx.allocator, header);

    // 项（.mi：padding 6 10、gap 9、radius 8、icon 16 列、sc 右注）
    try menu.appendChild(cx.allocator, try mi(cx, "✨", "问 AI（附选中输出）", "⌘J", false));
    try menu.appendChild(cx.allocator, try mi(cx, "⧉", "复制", "⌘C / 右键", false));
    try menu.appendChild(cx.allocator, try mi(cx, "📋", "粘贴", "⌘V", false));
    try menu.appendChild(cx.allocator, try ms(cx));
    try menu.appendChild(cx.allocator, try mi(cx, "▦", "矩形块选模式", "⌥+拖拽", false));
    try menu.appendChild(cx.allocator, try mi(cx, "🕐", "时间戳侧栏", "@ts", false));
    try menu.appendChild(cx.allocator, try mi(cx, "📜", "历史回溯", "@log", false));
    try menu.appendChild(cx.allocator, try ms(cx));
    try menu.appendChild(cx.allocator, try mi(cx, "🔍", "在终端中搜索", "⌘F", false));
    try menu.appendChild(cx.allocator, try mi(cx, "📤", "导出选中内容…", null, false));
    return menu;
}

fn mi(cx: *ui.Cx, icon: []const u8, label: []const u8, sc: ?[]const u8, danger: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .border = .{ .width = 0, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 16 },
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 12, .color = if (danger) tok.red else tok.fg2 }));
    try row.appendChild(cx.allocator, ic);
    try row.appendChild(cx.allocator, try ui.text(cx, label, .{ .font_size = 12.5, .color = if (danger) tok.red else tok.fg }));
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    if (sc) |s| {
        try row.appendChild(cx.allocator, try ui.text(cx, s, .{ .font_size = 10.5, .color = note }));
    }
    return row;
}

fn ms(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .margin = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 },
        .background = ui.Color.rgba(0, 0, 0, 15),
        .flex_shrink = 0,
    }, .{});
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "已连接  |  Terminal 中键=菜单 · 右键=复制/粘贴 · 与 Tab 菜单区分", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
