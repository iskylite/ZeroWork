//! mockup-sidebar-collapsed — 侧栏折叠态 48px 图标栏（docs/SPEC/html/mockup-sidebar-collapsed.html）。
//!
//! 结构：tbar(40) + main(592: sbc 48 + tp) + sbar(28)。总高 660。
//! 折叠态：34² 图标（radius 9）+ 左缘 5px 状态点；分隔线 22×1；
//! 悬浮提示与「⌘B 展开/折叠」注解浮层一并复刻。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 660 };
pub const title = "mockup-sidebar-collapsed";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountMain(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（页签 ×2 + 右侧图标） ──────────────────────────────────

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

    // 页签 ×2（K8s-Node01 on / 终端组: k8s-nodes off）
    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01 ✕", true));
    try bar.appendChild(cx.allocator, try tab(cx, "终端组: k8s-nodes ✕", false));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    // 右侧图标（无圆角版 .icn）
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

// ── 主体（sbc 48px 图标栏 + 终端） ─────────────────────────────────

fn mountMain(cx: *ui.Cx) !*ui.Node {
    const main_row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 592 },
        .direction = .row,
        .position = .relative,
        .flex_shrink = 0,
    }, .{});
    try main_row.appendChild(cx.allocator, try mountCollapsedSidebar(cx));
    try main_row.appendChild(cx.allocator, try mountTerminal(cx));
    // 悬浮提示（stip：left 58 top 120）
    const stip = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 120 }, .left = .{ .px = 58 } },
        .z_index = 30,
        .background = ui.Color.rgba(15, 23, 42, 235),
        .padding = .{ .left = 11, .right = 11, .top = 5, .bottom = 5 },
        .border = .{ .width = 0, .color = tok.fg, .radius = 7 },
    }, .{});
    try stip.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 · 10.200.1.18 · via Bastion — hover 显示主机详情", .{
        .font_size = 11,
        .color = tok.white,
    }));
    try main_row.appendChild(cx.allocator, stip);
    // 展开注解（expand-note：left 58 bottom 52）
    const note = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .bottom = .{ .px = 52 }, .left = .{ .px = 58 } },
        .z_index = 30,
    }, .{});
    try note.appendChild(cx.allocator, try ui.text(cx, "⌘B 展开/折叠 · 折叠态仅 48px 图标栏, 最大化终端面积", .{
        .font_size = 10,
        .color = tok.fg3,
    }));
    try main_row.appendChild(cx.allocator, note);
    return main_row;
}

/// 折叠侧栏图标项：34² radius 9 + 左缘 5px 状态点。
fn si(cx: *ui.Cx, icon: []const u8, on: bool, dot_color: ?ui.Color) !*ui.Node {
    const item = try ui.box(cx, .{
        .width = .{ .px = 34 },
        .height = .{ .px = 34 },
        .align_items = .center,
        .justify = .center,
        .background = if (on) tok.alpha(tok.acc, 26) else ui.Color.TRANSPARENT, // .1 ≈ 26
        .border = .{ .width = 0, .color = tok.acc, .radius = 9 },
        .flex_shrink = 0,
    }, .{});
    if (dot_color) |c| {
        const d = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .top = .{ .px = 14 }, .left = .{ .px = 2 } },
            .width = .{ .px = 5 },
            .height = .{ .px = 5 },
            .background = c,
            .border = .{ .width = 0, .color = c, .radius = 2.5 },
        }, .{});
        try item.appendChild(cx.allocator, d);
    }
    try item.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 15,
        .color = if (on) tok.acc else tok.fg2,
    }));
    return item;
}

fn mountCollapsedSidebar(cx: *ui.Cx) !*ui.Node {
    const sbc = try ui.box(cx, .{
        .width = .{ .px = 48 },
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .gap = 4,
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 8 },
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try sbc.appendChild(cx.allocator, try si(cx, "🔍", false, null));
    try sbc.appendChild(cx.allocator, try ssep(cx));
    try sbc.appendChild(cx.allocator, try si(cx, "🖥", false, tok.grn));
    try sbc.appendChild(cx.allocator, try si(cx, "⬡", true, tok.grn));
    try sbc.appendChild(cx.allocator, try si(cx, "⬡", false, tok.grn));
    try sbc.appendChild(cx.allocator, try si(cx, "🗄️", false, tok.off_dot));
    try sbc.appendChild(cx.allocator, try ssep(cx));
    try sbc.appendChild(cx.allocator, try si(cx, "🧪", false, tok.off_dot));
    try sbc.appendChild(cx.allocator, try si(cx, "🧪", false, tok.off_dot));
    try sbc.appendChild(cx.allocator, try ui.spacer(cx));
    try sbc.appendChild(cx.allocator, try si(cx, "＋", false, null));
    try sbc.appendChild(cx.allocator, try si(cx, "⇥", false, null));
    return sbc;
}

fn ssep(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = 22 },
        .height = .{ .px = 1 },
        .margin = .{ .top = 5, .right = 0, .bottom = 5, .left = 0 },
        .background = tok.bd,
        .flex_shrink = 0,
    }, .{});
}

fn mountTerminal(cx: *ui.Cx) !*ui.Node {
    const tp = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .overflow = .hidden,
    }, .{});
    const td = tok.alpha(tok.fg, 140); // .td opacity .55
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ htop", .color = tok.fg },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "  CPU[|||||||||||||          38%]   Mem[████████|          8.2G/31G]", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "  Tasks: 412, 987 thr; 2 running   Load average: 0.12 0.08 0.05", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "  Uptime: 85 days, 2:14:33", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "    PID USER      PRI  NI  VIRT   RES   SHR S  CPU%  MEM%   TIME+  Command", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "   1024 root       20   0 2412M 184M  42M S  12.3   0.6  3d 4:21  kubelet", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "   2388 ubuntu     20   0  982M  96M  18M S   4.1   0.3 12:41.02  containerd", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "   5512 ubuntu     20   0  412M  44M   9M S   1.2   0.1  1:02.44  node-exporter", .color = td },
    }, .{}));
    return tp;
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "Bastion-01 → k8s-node01  |  RTT 24ms  |  侧栏已折叠 (⌘B)", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
