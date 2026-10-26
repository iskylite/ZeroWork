//! mockup-ai-collapsed — AI 收起态迷你胶囊设计稿复刻
//! （docs/SPEC/html/mockup-ai-collapsed.html）。
//!
//! 结构：tbar(40) + term(520) + sbar(28)。窗口 1280×588。
//! term 顶边内嵌 5 组 44×10 迷你胶囊（三点状态机五态示例），
//! 每组下方配 .cap 注解胶囊；胶囊锚定 term 顶边（top 0）。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 588 };
pub const title = "mockup-ai-collapsed";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40px：红绿灯 + 单页签） ───────────────────────────

fn mountTitleBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 0, 0, 1, 0 } },
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

    // .tab：常亮选中样式（bg --bg + ring 阴影 + 12·500）
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
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区（term 520px，padding 14/38，行高 20） ──────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 520 },
        .direction = .column,
        .position = .relative,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 38, .bottom = 10 },
        .flex_shrink = 0,
    }, .{});

    // 三行终端内容（.ln 高 20，mono 13）
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl get pods -A | grep -v Running", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "prod-app    backend-api-7d9f4-x9p1r   1/1   Running   0   3h", .color = tok.grn },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .cursor = true }));

    // 五组 胶囊+注解：left = 200 / 470 / 740 / 950 / 1160
    try term.appendChild(cx.allocator, try pill(cx, 200, .{
        tok.alpha(tok.acc, 90), tok.alpha(tok.acc, 90), tok.alpha(tok.acc, 90),
    }));
    try term.appendChild(cx.allocator, try cap(cx, 200, "待机 · accent 35% 微光"));
    try term.appendChild(cx.allocator, try pill(cx, 470, .{ tok.acc, tok.cyn, tok.pur }));
    try term.appendChild(cx.allocator, try cap(cx, 470, "回合执行中 · 蓝→青→紫轮转流动 (1.2s/周期)"));
    try term.appendChild(cx.allocator, try pill(cx, 740, .{ tok.grn, tok.grn, tok.grn }));
    try term.appendChild(cx.allocator, try cap(cx, 740, "回合成功 · 绿常亮 3s 渐回待机"));
    try term.appendChild(cx.allocator, try pill(cx, 950, .{ tok.red, tok.red, tok.red }));
    try term.appendChild(cx.allocator, try cap(cx, 950, "失败/中止 · 红常亮至下次交互"));
    try term.appendChild(cx.allocator, try pill(cx, 1160, .{ tok.yel, tok.yel, tok.yel }));
    try term.appendChild(cx.allocator, try cap(cx, 1160, "待确认 · 琥珀呼吸"));
    return term;
}

/// .pill：44×10 顶边内嵌胶囊。底 white.85→theme.bg.55 垂直渐变，
/// 边 accent.22（顶边无线），圆角 0 0 7 7，阴影 accent.08。
fn pill(cx: *ui.Cx, left: f32, colors: [3]ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = left } },
        .width = .{ .px = 44 },
        .height = .{ .px = 10 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .gap = 3,
        .gradient = .{
            .from = tok.alpha(tok.white, 217), // rgba(255,255,255,.85)
            .to = tok.alpha(tok.bg, 140), // rgba(236,255,244,.55)
            .direction = .vertical,
        },
        .border = .{
            .width = 1,
            .color = tok.alpha(tok.acc, 56), // rgba(19,69,246,.22)
            .radius = 0,
            .side_widths = .{ 0, 1, 1, 1 }, // 顶边无线
        },
        .corner_radii = .{ .each = .{ 0, 0, 7, 7 } }, // 0 0 7 7（TL TR BR BL）
        .shadow = .{ .blur = 4, .offset_y = 1, .color = tok.alpha(tok.acc, 20) },
        .z_index = 10,
    }, .{});
    for (colors) |c| {
        try node.appendChild(cx.allocator, try mock.dot(cx, 3, c));
    }
    return node;
}

/// .cap：注解胶囊，水平中心对齐给定 x（CSS left + translateX(-50%)）。
/// 通过 520px 宽锚定盒 + justify center 实现（文字不超宽时不影响布局）。
fn cap(cx: *ui.Cx, center_x: f32, text: []const u8) !*ui.Node {
    const anchor = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 16 }, .left = .{ .px = center_x - 260 } },
        .width = .{ .px = 520 },
        .direction = .row,
        .justify = .center,
        .z_index = 10,
    }, .{});
    const pill_box = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = tok.alpha(tok.white, 217), // rgba(255,255,255,.85)
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 13), .radius = 5 },
        .flex_shrink = 0,
    }, .{});
    try pill_box.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 9.5,
        .color = tok.fg2,
    }));
    try anchor.appendChild(cx.allocator, pill_box);
    return anchor;
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
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, 0, 0, 0 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.grn));
    try bar.appendChild(cx.allocator, try ui.text(cx, "AI 状态浮条：44×10 迷你胶囊（只容三点，不占空间）· 三点状态机=待机/执行中三色轮转/成功绿/失败红/待确认琥珀 · hover 或 ⌘J 展开浮窗", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
