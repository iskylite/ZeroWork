//! mockup-search — ⌘F 终端搜索设计稿复刻（docs/SPEC/html/mockup-search.html）。
//!
//! 结构：tbar(40) + term(560) + sbar(28)。窗口 1280×628。要点（SPEC §12）：
//!  - 搜索条 360px 锚当前 pane 右上角（top 12 right 14）；
//!  - 输入框 mono 12.5 + 计数 "2 / 5" + ↑/↓/✕ 三按钮；
//!  - 当前命中 accent 蓝底白字，其余命中琥珀底 rgba(212,154,12,.28)；
//!  - 终端行 13.5px · line-height 1.7（行高 ≈23px），仅匹配滚动区不搜 gutter。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-search";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（40px，padding 0 12 gap 8） ───────────────────────────────

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

    // 单页签：bg 底 + 550 字重，无 on/off 之分。
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12,
        .font_weight = 550,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 终端（560px） ───────────────────────────────────────────────────

/// 13.5px mono 行（高 23 ≈ 13.5×1.7）。
fn line(cx: *ui.Cx, spans: []const mock.TermSpan) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 23 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    for (spans) |span| {
        try row.appendChild(cx.allocator, try ui.text(cx, span.text, .{
            .font_size = 13.5,
            .font_weight = span.weight,
            .color = span.color,
            .use_monospace_font = true,
            .line_height = 1.7,
        }));
    }
    return row;
}

/// 命中高亮 span：圆角 3 的底色块包 mono 文字（cur=蓝底白字 / hit=琥珀底）。
fn highlight(cx: *ui.Cx, text: []const u8, current: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .background = if (current) tok.acc else tok.alpha(tok.yel, 71), // rgba(212,154,12,.28)
        .border = .{ .width = 0, .color = tok.acc, .radius = 3 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 13.5,
        .font_weight = if (current) 500 else 400,
        .color = if (current) tok.white else tok.fg,
        .use_monospace_font = true,
        .line_height = 1.7,
    }));
    return node;
}

/// 搜索条按钮 30²。
fn findButton(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 30 },
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgb(0xF4, 0xFB, 0xF7), // #F4FBF7
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return node;
}

/// ⌘F 搜索条：360 宽，右上角锚定。
fn mountFindBar(cx: *ui.Cx) !*ui.Node {
    const find = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 12 }, .right = .{ .px = 14 } },
        .width = .{ .px = 360 },
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 250), // rgba(248,255,251,.98)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 36), .radius = 10 }, // rgba(19,69,246,.14)
        .shadow = .{ .blur = 32, .offset_y = 12, .color = ui.Color.rgba(15, 23, 42, 31) }, // rgba(15,23,42,.12)
        .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
        .z_index = 30,
        .flex_shrink = 0,
    }, .{});
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 6,
    }, .{});
    // 输入框：flex1 高 30 mono 12.5。
    const input = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 8, .right = 8, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .flex_shrink = 1,
    }, .{});
    try input.appendChild(cx.allocator, try ui.text(cx, "CrashLoop", .{
        .font_size = 12.5,
        .color = tok.fg,
        .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, input);
    // 计数：11px fg2 右对齐 min-width 54。
    const count = try ui.box(cx, .{
        .min_width = 54,
        .direction = .row,
        .justify = .end,
        .flex_shrink = 0,
    }, .{});
    try count.appendChild(cx.allocator, try ui.text(cx, "2 / 5", .{
        .font_size = 11,
        .color = tok.fg2,
        .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, count);
    try row.appendChild(cx.allocator, try findButton(cx, "↑"));
    try row.appendChild(cx.allocator, try findButton(cx, "↓"));
    try row.appendChild(cx.allocator, try findButton(cx, "✕"));
    try find.appendChild(cx.allocator, row);
    return find;
}

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .direction = .column,
        .padding = .{ .left = 16, .right = 16, .top = 14, .bottom = 14 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try term.appendChild(cx.allocator, try mountFindBar(cx));

    // 行1：prompt + 命令。
    const l1 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 23 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try l1.appendChild(cx.allocator, try ui.text(cx, "ubuntu", .{
        .font_size = 13.5, .color = tok.cyn, .use_monospace_font = true, .line_height = 1.7,
    }));
    try l1.appendChild(cx.allocator, try ui.text(cx, "@k8s-node01:~$ kubectl get pods", .{
        .font_size = 13.5, .color = tok.fg, .use_monospace_font = true, .line_height = 1.7,
    }));
    try term.appendChild(cx.allocator, l1);

    // 行2：backend-api + 当前命中(cur 蓝底) + BackOff   137。
    const l2 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 23 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try l2.appendChild(cx.allocator, try ui.text(cx, "backend-api   ", .{
        .font_size = 13.5, .color = tok.fg, .use_monospace_font = true, .line_height = 1.7,
    }));
    try l2.appendChild(cx.allocator, try highlight(cx, "CrashLoop", true));
    try l2.appendChild(cx.allocator, try ui.text(cx, "BackOff   137", .{
        .font_size = 13.5, .color = tok.fg, .use_monospace_font = true, .line_height = 1.7,
    }));
    try term.appendChild(cx.allocator, l2);

    // 行3：worker        Running                 0
    try term.appendChild(cx.allocator, try line(cx, &.{
        .{ .text = "worker        Running                 0", .color = tok.fg },
    }));

    // 行4：ingress + 命中(hit 琥珀底) + BackOff   2。
    const l4 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 23 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try l4.appendChild(cx.allocator, try ui.text(cx, "ingress       ", .{
        .font_size = 13.5, .color = tok.fg, .use_monospace_font = true, .line_height = 1.7,
    }));
    try l4.appendChild(cx.allocator, try highlight(cx, "CrashLoop", false));
    try l4.appendChild(cx.allocator, try ui.text(cx, "BackOff   2", .{
        .font_size = 13.5, .color = tok.fg, .use_monospace_font = true, .line_height = 1.7,
    }));
    try term.appendChild(cx.allocator, l4);

    // 提示行：margin-top 18，Inter 11px fg3。
    const hint = try ui.text(cx, "只搜索当前会话滚动区。Enter 下一个，⇧Enter 上一个，Esc 关闭。不跨会话，不搜 gutter 时间戳。", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.5,
    });
    const hint_wrap = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .margin = .{ .top = 18, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try hint_wrap.appendChild(cx.allocator, hint);
    try term.appendChild(cx.allocator, hint_wrap);
    return term;
}

// ── 状态栏（28px，无分隔点） ────────────────────────────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "⌘F 搜索当前终端 · 命中在滚动区高亮 · 当前命中用强调色", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
