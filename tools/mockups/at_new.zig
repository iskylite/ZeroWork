//! mockup-at-new — @new 新建会话设计稿复刻（docs/SPEC/html/mockup-at-new.html）。
//!
//! 结构：tbar(40) + term(560) + sbar(28)。窗口 1100×628。
//! 本稿无浮层卡：终端 7 行（组提示 + @new 执行回显 + 光标行）。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1100, .height = 628 };
pub const title = "mockup-at-new";

const tok = mock.tok;

const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏：组内两个 tab 均带 accent 1.5px 描边 ─────────────────────

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

    // 👥 K8s-Node01（组色描边，非 on）
    try bar.appendChild(cx.allocator, try tab(cx, "👥 K8s-Node01", false, true));
    // 👥 K8s-Node01 (2)（on + 组色描边）
    try bar.appendChild(cx.allocator, try tab(cx, "👥 K8s-Node01 (2)", true, true));
    // RDS-PG（普通）
    try bar.appendChild(cx.allocator, try tab(cx, "RDS-PG", false, false));

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️"));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool, group_outline: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        // html inline box-shadow: 0 0 0 1.5px acc（覆盖 .tab.on 原阴影）
        .outline = if (group_outline) .{ .color = tok.acc, .width = 1.5, .offset = 0 } else null,
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

// ── 终端区（term 560px，无浮层） ───────────────────────────────────

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
    // 行1：组提示
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "# 当前会话已属于终端组 \"k8s-nodes\"（Tab 组色描边）", .color = td },
    }, .{}));
    // 行2：$ @new
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
        .{ .text = "@new", .color = tok.acc, .weight = 600 },
    }, .{}));
    // 行3-6：回显
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 基于当前主机配置创建新会话…", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 当前在终端组 \"k8s-nodes\" → 新会话自动入组（第 2 个成员）", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "          标签 \"K8s-Node01 (2)\" 已创建 · 复用链路凭据（无需二次认证）", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "          对比: @dup 会额外镜像当前工作目录与上下文", .color = td },
    }, .{}));
    // 行7：光标行
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "@new · 基于当前主机新建会话；在组内则自动加入该组 · 凭据内存复用", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
