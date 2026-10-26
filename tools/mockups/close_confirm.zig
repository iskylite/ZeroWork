//! mockup-close-confirm — 关闭确认小模态设计稿复刻
//!（docs/SPEC/html/mockup-close-confirm.html）。
//!
//! 结构：tbar(40) + body(560，居中确认卡 520 宽：红标题 + 四行未完成事项清单
//! + 取消/仍然关闭按钮) + sbar(28)。窗口 1280×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-close-confirm";

const tok = mock.tok;

// HTML 内联色（:root token 之外的补充）
const row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // .row 上边线
const btn_bg = ui.Color.rgb(0xF8, 0xFA, 0xFC); // .b 底

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

// ── 标题栏（tbar 40px：红绿灯 + K8s-Node01 页签） ───────────────────

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
    try tab.appendChild(cx.allocator, try txt(cx, "K8s-Node01 ✕", 12, 500, tok.fg, 1.2));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 主体（body 560：压暗背板 + 确认卡 520 居中） ────────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    const body = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
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
        .background = tok.alpha(tok.bg, 128), // rgba(236,255,244,.5)
        .glass = .{ .backdrop_blur = 5 },
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    try body.appendChild(cx.allocator, ov);
    return body;
}

fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 520 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 247), // rgba(248,255,251,.97)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 31), .radius = 12 }, // rgba(19,69,246,.12)
        .shadow = .{ .blur = 48, .offset_y = 18, .color = ui.Color.rgba(15, 23, 42, 41) },
        .padding = .{ .left = 20, .right = 20, .top = 18, .bottom = 20 },
        .flex_shrink = 0,
    }, .{});

    // 标题（危险色）+ 副说明
    const h = try ui.box(cx, .{ .width = .fill(), .flex_shrink = 0 }, .{});
    try h.appendChild(cx.allocator, try txt(cx, "关闭 K8s-Node01？", 14, 650, tok.red, 1.2));
    const sub = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .top = 4, .right = 0, .bottom = 12, .left = 0 },
    }, .{});
    try sub.appendChild(cx.allocator, try txt(cx, "还有未结束的工作。取消则保持页签；确认关闭会按下面规则清理。", 11, 400, tok.fg3, 1.4));
    try h.appendChild(cx.allocator, sub);
    try card.appendChild(cx.allocator, h);

    // 未完成事项清单（每行均有上边线分隔）
    try card.appendChild(cx.allocator, try krow(cx, "传输", "app.tar.gz 62% · 关闭将暂停，下次可续传"));
    try card.appendChild(cx.allocator, try krow(cx, "AI", "1 条写命令执行中 · 关闭即走中止清理（^C → TERM → KILL）"));
    try card.appendChild(cx.allocator, try krow(cx, "SOCKS5", ":1080 将随会话释放 · 3 个代理连接断开"));
    try card.appendChild(cx.allocator, try krow(cx, "历史", "滚动区已落盘，关闭后仍可从侧栏「查看历史」回放"));

    // 按钮行
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
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .background = btn_bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try cancel.appendChild(cx.allocator, try txt(cx, "取消", 12, 400, tok.fg2, 1.2));
    try btns.appendChild(cx.allocator, cancel);
    const close = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .background = btn_bg,
        .border = .{ .width = 1, .color = tok.alpha(tok.red, 89), .radius = 8 }, // rgba(220,76,63,.35)
        .flex_shrink = 0,
    }, .{});
    try close.appendChild(cx.allocator, try txt(cx, "仍然关闭", 12, 400, tok.red, 1.2));
    try btns.appendChild(cx.allocator, close);
    try card.appendChild(cx.allocator, btns);
    return card;
}

// ── 清单行（.k 92px + 说明，首行也有上边线） ────────────────────────

fn krow(cx: *ui.Cx, k: []const u8, v: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 8 },
        .border = .{ .width = 1, .color = row_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const k_node = try ui.box(cx, .{
        .width = .{ .px = 92 },
        .flex_shrink = 0,
    }, .{});
    try k_node.appendChild(cx.allocator, try txt(cx, k, 12, 400, tok.fg2, 1.2));
    try row.appendChild(cx.allocator, k_node);
    const v_node = try ui.box(cx, .{ .flex = 1, .min_width = 0 }, .{});
    try v_node.appendChild(cx.allocator, try txt(cx, v, 12, 400, tok.fg, 1.2));
    try row.appendChild(cx.allocator, v_node);
    return row;
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
    try bar.appendChild(cx.allocator, try txt(cx, "关页签/关窗口前：有传输、AI 写命令或 SOCKS 监听时必须确认", 11, 400, tok.fg2, 1.2));
    return bar;
}
