//! mockup-at-grp — @grp 终端组设计稿复刻（docs/SPEC/html/mockup-at-grp.html）。
//!
//! 结构：tbar(40) + term(560, 顶端 90 处挂 400 宽组卡) + sbar(28)。窗口 1100×628。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1100, .height = 628 };
pub const title = "mockup-at-grp";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb
const c_line7 = ui.Color.rgba(15, 23, 42, 18); // 卡边框 rgba(15,23,42,.07)
const c_line5 = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const c_gray_dot = ui.Color.rgb(0xCB, 0xD5, 0xE1); // #CBD5E1

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏 ─────────────────────────────────────────────────────────

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

    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01", true));

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️"));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = if (on) .{ .width = 1, .color = tok.bd, .radius = 7 } else .{ .width = 0, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    }));
    try node.appendChild(cx.allocator, try ui.text(cx, "✕", .{ .font_size = 9, .color = tok.fg3 }));
    return node;
}

fn globalIcon(cx: *ui.Cx, icon: []const u8) !*ui.Node {
    const icn = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 14,
        .color = if (std.mem.eql(u8, icon, "✨")) tok.acc else tok.fg2,
    }));
    return icn;
}

// ── 终端区 + 组卡（ov 透明，顶端 90） ───────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    const td = tok.alpha(tok.fg, 140);
    // 行1：$ @grp k8s-nodes
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@grp k8s-nodes", .color = tok.acc, .weight = 600 },
    }, .{}));
    // 行2
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 终端组 \"k8s-nodes\" 已创建 · 当前会话已加入 (1 个成员)", .color = td },
    }, .{}));
    // 行3：@grp k8s-nodes 为 acc 60%（td 行内混排）
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "          在其他会话输入 ", .color = td },
        .{ .text = "@grp k8s-nodes", .color = tok.alpha(tok.acc, 178) }, // opacity .7
        .{ .text = " 加入 · @sync on 开启广播", .color = td },
    }, .{}));
    // 行4：光标行
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));

    // 组卡（ov 透明、align flex-start、padding-top 90、水平居中）
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 1100 },
        .height = .{ .px = 560 },
        .direction = .column,
        .align_items = .center,
        .z_index = 10,
    }, .{});
    const card = try ui.box(cx, .{
        .width = .{ .px = 400 },
        .direction = .column,
        .margin = .{ .top = 90, .right = 0, .bottom = 0, .left = 0 },
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242),
        .border = .{ .width = 1, .color = c_line7, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) },
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 20,
        .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 },
    }, .{});

    // 标题行：👥 终端组: k8s-nodes + 「新创建」徽标
    const head = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "👥 终端组: k8s-nodes", .{
        .font_size = 12.5, .font_weight = 600, .color = tok.fg,
    }));
    const badge_new = try ui.box(cx, .{
        .padding = .{ .left = 7, .right = 7, .top = 2, .bottom = 2 },
        .background = tok.alpha(tok.acc, 26), // rgba(19,69,246,.1)
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
    }, .{});
    try badge_new.appendChild(cx.allocator, try ui.text(cx, "新创建", .{
        .font_size = 9.5, .font_weight = 600, .color = tok.acc,
    }));
    try head.appendChild(cx.allocator, badge_new);
    try card.appendChild(cx.allocator, head);

    // 成员列表
    const members = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 6,
    }, .{});
    // 成员1：acc 点 + 名称 + 右注
    const m1 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
    }, .{});
    try m1.appendChild(cx.allocator, try mock.dot(cx, 8, tok.acc));
    try m1.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01", .{
        .font_size = 11.5, .color = tok.fg,
    }));
    try m1.appendChild(cx.allocator, try ui.spacer(cx));
    try m1.appendChild(cx.allocator, try ui.text(cx, "当前会话 · 组色已染色", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try members.appendChild(cx.allocator, m1);
    // 成员2：50% 透明等待行
    const m2 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .opacity = 0.5,
    }, .{});
    try m2.appendChild(cx.allocator, try mock.dot(cx, 8, c_gray_dot));
    try m2.appendChild(cx.allocator, try ui.text(cx, "等待其他会话 @grp k8s-nodes 加入…", .{
        .font_size = 11.5, .color = tok.fg,
    }));
    try members.appendChild(cx.allocator, m2);
    try card.appendChild(cx.allocator, members);

    // 底注（上分隔线）
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .margin = .{ .top = 10, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 9, .bottom = 0 },
        .border = .{ .width = 1, .color = c_line5, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
    }, .{});
    try foot.appendChild(cx.allocator, try ui.text(cx, "组内会话可用 ⌘⇧I / @sync on 广播输入 · AI 可整组下发命令", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try card.appendChild(cx.allocator, foot);

    try ov.appendChild(cx.allocator, card);
    try term.appendChild(cx.allocator, ov);
    return term;
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "内置指令 @grp · 创建/加入终端组 · Tab 角标与 Pane 边框同步染组色", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
