//! mockup-empty — 首次启动空态（docs/SPEC/html/mockup-empty.html）。
//!
//! 结构：tbar(40) + body(560: 侧栏 224 空态 + 主区引导) + sbar(28)。总高 628。
//! 规格：空态无页签、无右上图标（仅红绿灯）；侧栏只有「还没有主机」+ 新建按钮。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-empty";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
        try mountStatusBar(cx),
    });
}

fn mountTitleBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const tls = try ui.box(cx, .{ .direction = .row, .gap = 8 }, .{});
    for ([_]ui.Color{ ui.Color.rgb(0xFF, 0x5F, 0x57), ui.Color.rgb(0xFF, 0xBD, 0x2E), ui.Color.rgb(0x28, 0xC8, 0x40) }) |c| {
        try tls.appendChild(cx.allocator, try mock.dot(cx, 12, c));
    }
    try bar.appendChild(cx.allocator, tls);
    return bar;
}

fn mountBody(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{
        try mountEmptySidebar(cx),
        try mountEmptyMain(cx),
    });
}

fn mountEmptySidebar(cx: *ui.Cx) !*ui.Node {
    const sb = try ui.box(cx, .{
        .width = .{ .px = 224 },
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 16, .bottom = 16 },
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try sb.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 15 },
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
    }, .{try ui.text(cx, "还没有主机", .{
        .font_size = 11,
        .color = tok.fg3,
    })}));
    // ＋ 新建连接：全宽渐变主按钮（grad 135deg ≈ diagonal）。
    const btn = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 32 },
        .align_items = .center,
        .justify = .center,
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
    }, .{});
    try btn.appendChild(cx.allocator, try ui.text(cx, "＋ 新建连接", .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.white,
    }));
    try sb.appendChild(cx.allocator, btn);
    return sb;
}

fn mountEmptyMain(cx: *ui.Cx) !*ui.Node {
    const area = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .align_items = .center,
        .justify = .center,
        .background = tok.bg,
    }, .{});
    // 居中引导卡（max-width 360）
    const card = try ui.box(cx, .{
        .width = .{ .px = 360 },
        .align_items = .center,
    }, .{});
    try card.appendChild(cx.allocator, try ui.text(cx, "从一条 SSH 连接开始", .{
        .font_size = 16,
        .font_weight = 650,
        .color = tok.fg,
    }));
    try card.appendChild(cx.allocator, try ui.text(cx, "⌘K 快速连接，或 ⌘N 打开新建向导。AI、SOCKS5、SFTP 都挂在会话上，先有主机会话才可用。", .{
        .font_size = 11,
        .color = tok.fg3,
        .wrap = .word,
        .text_align = .center,
        .line_height = 1.5,
    }));
    const btns = try ui.box(cx, .{
        .direction = .row,
        .gap = 8,
        .margin = .{ .top = 12, .right = 0, .bottom = 0, .left = 0 },
    }, .{});
    const primary = try ui.box(cx, .{
        .height = .{ .px = 30 },
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
    }, .{});
    try primary.appendChild(cx.allocator, try ui.text(cx, "新建连接", .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.white,
    }));
    try btns.appendChild(cx.allocator, primary);
    try btns.appendChild(cx.allocator, try mock.secondaryButton(cx, "导入现有配置"));
    try card.appendChild(cx.allocator, btns);
    try area.appendChild(cx.allocator, card);
    return area;
}

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "首次启动空态：无主机、无页签。不展示假会话，也不提前展开 AI", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
