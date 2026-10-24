//! mockup-broadcast — 广播模式设计稿复刻（docs/SPEC/html/mockup-broadcast.html）。
//!
//! 结构：tbar(40) + grid(520: 2×2 pane 阵列) + bbar(38) + sbar(28)。窗口 1280×626。
//! 要点（SPEC §8）：
//!  - 组内 pane 以组色描边：html 用 grid 底 --grp + padding/gap 3px 形成分隔描边；
//!  - 焦点 pane 内缩 2px 描边（outline 2px acc offset -2 → border 2 近似）；
//!  - pane 右上角标签（组色底白字 9.5px）；
//!  - 广播条：开关(on) + 「广播输入: ON」+ 4 个成员胶囊 + 右注。
//!
//! 说明：任务简报提到的「📌 置顶」「● 广播中」角标与「输入回显条贴底行」
//! 不存在于本 html（ground truth 无此元素），以 html 为准不复刻。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 626 };
pub const title = "mockup-broadcast";

const tok = mock.tok;
const grp = tok.acc; // --grp = #1345F6 = accent

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountPaneGrid(cx),
        try mountBroadcastBar(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（40px） ─────────────────────────────────────────────────

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

    // on 页签：文字 + 「4 PANES」徽标 + ✕（gap 6）。
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "终端组: k8s-nodes", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    const gtag = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
        .background = tok.alpha(tok.acc, 26), // rgba(19,69,246,.1)
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try gtag.appendChild(cx.allocator, try ui.text(cx, "4 PANES", .{
        .font_size = 9,
        .font_weight = 600,
        .color = tok.acc,
    }));
    try tab.appendChild(cx.allocator, gtag);
    try tab.appendChild(cx.allocator, try ui.text(cx, "✕", .{ .font_size = 9, .color = tok.fg3 }));
    try bar.appendChild(cx.allocator, tab);

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡", false));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅", false));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨", true));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️", false));
    return bar;
}

fn globalIcon(cx: *ui.Cx, icon: []const u8, accent: bool) !*ui.Node {
    const icn = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 14,
        .color = if (accent) tok.acc else tok.fg2,
    }));
    return icn;
}

// ── 2×2 pane 阵列（520px，组色描边） ───────────────────────────────

/// pane 行：高 18（12px · 1.5 行高），mono 12。
fn pLine(cx: *ui.Cx, spans: []const mock.TermSpan) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 18 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    for (spans) |span| {
        try row.appendChild(cx.allocator, try ui.text(cx, span.text, .{
            .font_size = 12,
            .font_weight = span.weight,
            .color = span.color,
            .use_monospace_font = true,
            .line_height = 1.5,
        }));
    }
    return row;
}

const td = tok.alpha(tok.fg, 140); // .td opacity .55

/// pane：bg 底、padding 8/11、右上角标签、可选焦点描边。
fn mountPane(cx: *ui.Cx, label: []const u8, host: []const u8, fetched: []const u8, with_reading: bool, focus: bool) !*ui.Node {
    const pane = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 11, .right = 11, .top = 8, .bottom = 8 },
        .background = tok.bg,
        .border = if (focus) .{ .width = 2, .color = grp, .radius = 0 } else null, // outline 2 offset -2
        .overflow = .hidden,
        .min_width = 0,
    }, .{});
    // 右上角标签：组色底白字 9.5px。
    const pl = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 6 }, .right = .{ .px = 9 } },
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = grp,
        .border = .{ .width = 0, .color = grp, .radius = 4 },
        .opacity = 0.9,
    }, .{});
    try pl.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 9.5,
        .font_weight = 500,
        .color = tok.white,
    }));
    try pane.appendChild(cx.allocator, pl);

    // 首行 prompt：ubuntu@<host>:~$ sudo apt …
    try pane.appendChild(cx.allocator, try pLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@", .color = tok.fg },
        .{ .text = host, .color = tok.fg },
        .{ .text = ":", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ sudo apt update && sudo apt upgrade -y", .color = tok.fg },
    }));
    try pane.appendChild(cx.allocator, try pLine(cx, &.{
        .{ .text = "Hit:1 http://archive.ubuntu.com jammy InRelease", .color = td },
    }));
    try pane.appendChild(cx.allocator, try pLine(cx, &.{
        .{ .text = "Get:2 http://security.ubuntu.com jammy-security [12.3 MB]", .color = td },
    }));
    try pane.appendChild(cx.allocator, try pLine(cx, &.{
        .{ .text = fetched, .color = td },
    }));
    if (with_reading) {
        try pane.appendChild(cx.allocator, try pLine(cx, &.{
            .{ .text = "Reading package lists... Done", .color = td },
        }));
    }
    // 输入行：prompt + 7×15 光标。
    const input_row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 18 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try input_row.appendChild(cx.allocator, try ui.text(cx, "ubuntu", .{
        .font_size = 12, .color = tok.cyn, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, std.fmt.allocPrint(cx.allocator, "@{s}:", .{host}) catch "@node:", .{
        .font_size = 12, .color = tok.fg, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "~", .{
        .font_size = 12, .color = tok.acc2, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "$ ", .{
        .font_size = 12, .color = tok.fg, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 7 },
        .height = .{ .px = 15 },
        .background = tok.fg,
        .flex_shrink = 0,
    }, .{}));
    try pane.appendChild(cx.allocator, input_row);
    return pane;
}

fn mountPaneGrid(cx: *ui.Cx) !*ui.Node {
    // 组色底 + 3px padding + 3px gap = 组色描边效果（html .grid）。
    const grid = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 520 },
        .direction = .column,
        .gap = 3,
        .padding = .{ .left = 3, .right = 3, .top = 3, .bottom = 3 },
        .background = grp,
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{});

    const row1 = try ui.box(cx, .{
        .width = .fill(),
        .flex = 1,
        .direction = .row,
        .gap = 3,
        .overflow = .hidden,
        .min_height = 0,
    }, .{
        try mountPane(cx, "node01 · 焦点", "node01", "Fetched 14.1 MB in 3s (4,702 kB/s)", true, true),
        try mountPane(cx, "node02", "node02", "Fetched 14.1 MB in 2s (6,113 kB/s)", true, false),
    });
    const row2 = try ui.box(cx, .{
        .width = .fill(),
        .flex = 1,
        .direction = .row,
        .gap = 3,
        .overflow = .hidden,
        .min_height = 0,
    }, .{
        try mountPane(cx, "node03", "node03", "Fetched 14.1 MB in 4s (3,521 kB/s)", false, false),
        try mountPane(cx, "node04", "node04", "Fetched 14.1 MB in 3s (4,918 kB/s)", false, false),
    });
    try grid.appendChild(cx.allocator, row1);
    try grid.appendChild(cx.allocator, row2);
    return grid;
}

// ── 广播条（38px） ─────────────────────────────────────────────────

/// 成员胶囊：白底 + acc .25 边 + acc 字 10.5·500。
fn memberChip(cx: *ui.Cx, name: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 2, .bottom = 2 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 64), .radius = 10 }, // rgba(19,69,246,.25)
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 10.5,
        .font_weight = 500,
        .color = tok.acc,
    }));
    return node;
}

fn mountBroadcastBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 38 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .gradient = .{
            .from = tok.alpha(tok.acc, 20), // rgba(19,69,246,.08)
            .to = tok.alpha(tok.acc, 8), // rgba(19,69,246,.03)
            .direction = .horizontal,
        },
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 51), .radius = 0, .side_widths = .{ 1, -1, -1, -1 } }, // rgba(19,69,246,.2)
        .flex_shrink = 0,
    }, .{});
    // 开关（on）。
    try bar.appendChild(cx.allocator, try mock.toggle(cx, true));
    try bar.appendChild(cx.allocator, try ui.text(cx, "广播输入: ON", .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.acc,
    }));
    // 成员胶囊组（margin-left 6）。
    const bmem = try ui.box(cx, .{
        .direction = .row,
        .gap = 5,
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 6 },
        .flex_shrink = 0,
    }, .{});
    for ([_][]const u8{ "node01", "node02", "node03", "node04" }) |name| {
        try bmem.appendChild(cx.allocator, try memberChip(cx, name));
    }
    try bar.appendChild(cx.allocator, bmem);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "击键同步至 4 个终端 · ⌘⇧I 切换 · ✨ AI 可将本组作为整体下发命令并聚合输出", .{
        .font_size = 10.5,
        .color = tok.fg2,
    }));
    return bar;
}

// ── 状态栏（28px） ─────────────────────────────────────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "组 k8s-nodes: 4/4 在线", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "平均 RTT 31ms", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
