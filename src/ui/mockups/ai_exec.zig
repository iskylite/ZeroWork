//! mockup-ai-exec — AI-Exec 执行状态卡设计稿复刻
//! （docs/SPEC/html/mockup-ai-exec.html）。
//!
//! 结构：tbar(40) + term(600：ov 压暗层 + af 浮窗 620 宽) + sbar(28)。
//! 窗口 1280×668。浮窗含三张 AI-Exec 卡：执行中(spinner/可停止/组扇出)、
//! 完成(exit 0 绿徽标)、失败(exit 1 红徽标 + ✨分析原因)。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 668 };
pub const title = "mockup-ai-exec";

const tok = mock.tok;

const af_bg = ui.Color.rgba(248, 255, 251, 242); // rgba(248,255,251,.95)
const hairline = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const slate200 = ui.Color.rgb(226, 232, 240); // #E2E8F0
const slate100 = ui.Color.rgb(241, 245, 249); // #F1F5F9
const dark_bg = ui.Color.rgb(0x0F, 0x17, 0x2A); // #0F172A
const dark_fg = ui.Color.rgb(226, 232, 240); // #E2E8F0
const grn_dollar = ui.Color.rgb(0x34, 0xD3, 0x99); // #34D399
const grn_deep = ui.Color.rgb(0x05, 0x96, 0x69); // #059669
const spinner_hole = ui.Color.rgb(246, 248, 255); // rgba(19,69,246,.04) over #fff

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40：单页签 组会话） ───────────────────────────────

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
    try tab.appendChild(cx.allocator, try ui.text(cx, "👥 终端组: k8s-nodes ✕", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}

// ── 终端区（600px：压暗层 + AI 浮窗） ──────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .column,
        .position = .relative,
        .background = tok.bg,
        .flex_shrink = 0,
    }, .{});
    // .ov 压暗层：theme.bg.35 + blur(3)
    try term.appendChild(cx.allocator, try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .background = tok.alpha(tok.bg, 89),
        .glass = .{ .backdrop_blur = 3 },
        .z_index = 10,
    }, .{}));
    try term.appendChild(cx.allocator, try mountAIFloat(cx));
    return term;
}

// ── AI 浮窗（620 宽，顶中央 top14） ────────────────────────────────

fn mountAIFloat(cx: *ui.Cx) !*ui.Node {
    const af = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 14 }, .left = .{ .px = 330 } },
        .width = .{ .px = 620 },
        .direction = .column,
        .background = af_bg,
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) },
        .overflow = .hidden,
        .z_index = 20,
    }, .{
        try mountGrip(cx),
        try mountHeader(cx),
        try mountCards(cx),
    });
    return af;
}

/// .af-grip：14px 拖拽条区（无底色），36×4 圆角条。
fn mountGrip(cx: *ui.Cx) !*ui.Node {
    const grip = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 14 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try grip.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 36 },
        .height = .{ .px = 4 },
        .background = tok.alpha(tok.acc, 64), // rgba(19,69,246,.25)
        .border = .{ .width = 0, .color = tok.acc, .radius = 2 },
    }, .{}));
    return grip;
}

/// .af-h：✨ + 标题 13·600 + 作用域 chip + Esc 收起。高 39。
fn mountHeader(cx: *ui.Cx) !*ui.Node {
    const header = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 39 },
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .padding = .{ .left = 14, .right = 14, .top = 5, .bottom = 9 },
        .border = .{ .width = 1, .color = hairline, .radius = 0, .side_widths = .{ 0, 0, 1, 0 } },
        .flex_shrink = 0,
    }, .{});
    try header.appendChild(cx.allocator, try ui.text(cx, "✨", .{ .font_size = 16 }));
    try header.appendChild(cx.allocator, try ui.text(cx, "AI 运维助手", .{
        .font_size = 13,
        .font_weight = 600,
        .color = tok.fg,
    }));
    const scope = try ui.box(cx, .{
        .height = .{ .px = 21 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 13),
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 31), .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try scope.appendChild(cx.allocator, try ui.text(cx, "👥 终端组: k8s-nodes (4) ▾", .{
        .font_size = 10.5,
        .color = tok.acc,
    }));
    try header.appendChild(cx.allocator, scope);
    try header.appendChild(cx.allocator, try ui.spacer(cx));
    try header.appendChild(cx.allocator, try ui.text(cx, "Esc 收起 ✕", .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    return header;
}

// ── af-c：说明行 + 三张执行状态卡 ──────────────────────────────────

fn mountCards(cx: *ui.Cx) !*ui.Node {
    const cards = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 },
    }, .{});

    // 说明行（11px fg3）
    const intro = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 13 },
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 0, .right = 0, .bottom = 8, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try intro.appendChild(cx.allocator, try ui.text(cx, "命令批准后的后续状态（处理项全流程）：", .{
        .font_size = 11,
        .color = tok.fg3,
    }));
    try cards.appendChild(cx.allocator, intro);
    try cards.appendChild(cx.allocator, try mountCardRunning(cx));
    try cards.appendChild(cx.allocator, try mountCardDone(cx));
    try cards.appendChild(cx.allocator, try mountCardFailed(cx));
    return cards;
}

/// 卡1 执行中：spinner + 标题 + 命令 + 耗时 + ■停止；组扇出逐会话行。
fn mountCardRunning(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 93 }, // 32 exh + 32 exc + 27 gr + 2 border
        .direction = .column,
        .margin = .{ .top = 0, .right = 0, .bottom = 9, .left = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = slate200, .radius = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});

    // .exh 执行中头：底 rgba(19,69,246,.04)
    const exh = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .background = tok.alpha(tok.acc, 10),
        .flex_shrink = 0,
    }, .{});
    try exh.appendChild(cx.allocator, try spinner(cx, 12, spinner_hole));
    try exh.appendChild(cx.allocator, try ui.text(cx, "执行中", .{
        .font_size = 11,
        .font_weight = 700,
        .color = tok.fg,
    }));
    try exh.appendChild(cx.allocator, try ui.text(cx, "kubectl set resources deploy/backend-api …", .{
        .font_size = 11,
        .font_weight = 400,
        .color = tok.fg3,
    }));
    try exh.appendChild(cx.allocator, try ui.text(cx, "已耗时 3.2s", .{
        .font_size = 11,
        .font_weight = 400,
        .color = tok.fg3,
    }));
    try exh.appendChild(cx.allocator, try ui.spacer(cx));
    // .stop 停止按钮
    const stop = try ui.box(cx, .{
        .height = .{ .px = 17 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 0, .bottom = 0 },
        .border = .{ .width = 1, .color = tok.alpha(tok.red, 77), .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try stop.appendChild(cx.allocator, try ui.text(cx, "■ 停止", .{
        .font_size = 10,
        .color = tok.red,
    }));
    try exh.appendChild(cx.allocator, stop);
    try card.appendChild(cx.allocator, exh);

    // .exc 命令体：深底绿$
    const exc = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .background = dark_bg,
        .flex_shrink = 0,
    }, .{});
    try exc.appendChild(cx.allocator, try ui.text(cx, "$", .{
        .font_size = 10.5,
        .color = grn_dollar,
        .use_monospace_font = true,
        .line_height = 1.55,
    }));
    try exc.appendChild(cx.allocator, try ui.text(cx, " kubectl set resources deploy/backend-api -n prod-app --limits=memory=512Mi", .{
        .font_size = 10.5,
        .color = dark_fg,
        .use_monospace_font = true,
        .line_height = 1.55,
    }));
    try card.appendChild(cx.allocator, exc);

    // .gr 组扇出逐会话状态行（✓✓✓ spinner…）
    const gr = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 27 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 4 },
        .flex_shrink = 0,
    }, .{});
    try gr.appendChild(cx.allocator, try ui.text(cx, "✓", .{ .font_size = 10.5, .color = tok.grn }));
    try gr.appendChild(cx.allocator, try ui.text(cx, "node01", .{ .font_size = 10.5, .color = tok.fg2 }));
    try gr.appendChild(cx.allocator, try ui.text(cx, "✓", .{ .font_size = 10.5, .color = tok.grn }));
    try gr.appendChild(cx.allocator, try ui.text(cx, "node02", .{ .font_size = 10.5, .color = tok.fg2 }));
    try gr.appendChild(cx.allocator, try ui.text(cx, "✓", .{ .font_size = 10.5, .color = tok.grn }));
    try gr.appendChild(cx.allocator, try ui.text(cx, "node03", .{ .font_size = 10.5, .color = tok.fg2 }));
    try gr.appendChild(cx.allocator, try spinner(cx, 9, tok.white));
    try gr.appendChild(cx.allocator, try ui.text(cx, "node04…", .{ .font_size = 10.5, .color = tok.fg2 }));
    try gr.appendChild(cx.allocator, try ui.spacer(cx));
    try gr.appendChild(cx.allocator, try tag(cx, "exec_group 扇出", tok.acc, tok.alpha(tok.acc, 15)));
    try card.appendChild(cx.allocator, gr);
    return card;
}

/// 卡2 已完成：exit 0 绿徽标 + 结果行（结果注入上下文）。
fn mountCardDone(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 63 }, // 31 exh + 30 exr + 2 border
        .direction = .column,
        .margin = .{ .top = 0, .right = 0, .bottom = 9, .left = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = slate200, .radius = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    const exh = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .background = tok.alpha(tok.grn, 13), // rgba(16,185,129,.05)
        .flex_shrink = 0,
    }, .{});
    try exh.appendChild(cx.allocator, try ui.text(cx, "✓", .{ .font_size = 11, .color = tok.grn }));
    try exh.appendChild(cx.allocator, try ui.text(cx, "已完成", .{
        .font_size = 11,
        .font_weight = 700,
        .color = tok.fg,
    }));
    try exh.appendChild(cx.allocator, try tag(cx, "exit 0", grn_deep, tok.alpha(tok.grn, 26)));
    try exh.appendChild(cx.allocator, try ui.text(cx, "kubectl rollout restart · 4/4 会话 · 8.4s", .{
        .font_size = 11,
        .font_weight = 400,
        .color = tok.fg3,
    }));
    try card.appendChild(cx.allocator, exh);

    // .exr 结果行：mono，上边框 #F1F5F9
    const exr = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .border = .{ .width = 1, .color = slate100, .radius = 0, .side_widths = .{ 1, 0, 0, 0 } },
        .flex_shrink = 0,
    }, .{});
    try exr.appendChild(cx.allocator, try ui.text(cx, "deployment.apps/backend-api restarted", .{
        .font_size = 10.5,
        .color = tok.fg2,
        .use_monospace_font = true,
        .line_height = 1.5,
    }));
    try exr.appendChild(cx.allocator, try ui.text(cx, "（全组一致 · 结果已注入 AI 上下文）", .{
        .font_size = 10.5,
        .color = tok.alpha(tok.fg3, 153), // opacity .6
        .use_monospace_font = true,
        .line_height = 1.5,
    }));
    try card.appendChild(cx.allocator, exr);
    return card;
}

/// 卡3 失败：exit 1 红徽标 + ✨分析原因；红色错误结果行。
fn mountCardFailed(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 63 },
        .direction = .column,
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = slate200, .radius = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    const exh = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .background = tok.alpha(tok.red, 13), // rgba(220,76,63,.05)
        .flex_shrink = 0,
    }, .{});
    try exh.appendChild(cx.allocator, try ui.text(cx, "✗", .{ .font_size = 11, .color = tok.red }));
    try exh.appendChild(cx.allocator, try ui.text(cx, "失败", .{
        .font_size = 11,
        .font_weight = 700,
        .color = tok.fg,
    }));
    try exh.appendChild(cx.allocator, try tag(cx, "exit 1", tok.red, tok.alpha(tok.red, 26)));
    try exh.appendChild(cx.allocator, try ui.text(cx, "node03 · 2.1s", .{
        .font_size = 11,
        .font_weight = 400,
        .color = tok.fg3,
    }));
    try exh.appendChild(cx.allocator, try ui.spacer(cx));
    try exh.appendChild(cx.allocator, try ui.text(cx, "✨ 分析原因", .{
        .font_size = 10.5,
        .color = tok.acc,
    }));
    try card.appendChild(cx.allocator, exh);

    const exr = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .border = .{ .width = 1, .color = slate100, .radius = 0, .side_widths = .{ 1, 0, 0, 0 } },
        .flex_shrink = 0,
    }, .{});
    try exr.appendChild(cx.allocator, try ui.text(cx, "Error from server (NotFound): deployments \"backend-api\" not found", .{
        .font_size = 10.5,
        .color = tok.red,
        .use_monospace_font = true,
        .line_height = 1.5,
    }));
    try exr.appendChild(cx.allocator, try ui.text(cx, "（node03 命名空间不同）", .{
        .font_size = 10.5,
        .color = tok.fg3,
        .use_monospace_font = true,
        .line_height = 1.5,
    }));
    try card.appendChild(cx.allocator, exr);
    return card;
}

// ── 局部部件 ───────────────────────────────────────────────────────

/// .tag 徽标：字 9·600，底 10% 语义色，圆角 4，padding 2 7。
fn tag(cx: *ui.Cx, label: []const u8, fg: ui.Color, bg: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 15 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 0, .bottom = 0 },
        .background = bg,
        .border = .{ .width = 0, .color = fg, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 9,
        .font_weight = 600,
        .color = fg,
    }));
    return node;
}

/// .spin：conic spinner（accent 顶部 25% + 20% 蓝轨），中心孔填底色。
/// CSS border 2px 环：外 size，孔 size-4。
fn spinner(cx: *ui.Cx, size: f32, hole_color: ui.Color) !*ui.Node {
    const track = tok.alpha(tok.acc, 51); // rgba(19,69,246,.2)
    const node = try ui.box(cx, .{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .align_items = .center,
        .justify = .center,
        .multi_gradient = ui.MultiGradient.fromSlice(&.{
            .{ .color = tok.acc, .position = 0.0 },
            .{ .color = tok.acc, .position = 0.25 },
            .{ .color = track, .position = 0.25 },
            .{ .color = track, .position = 1.0 },
        }, .conic),
        .rotate = -std.math.pi / 2.0,
        .flex_shrink = 0,
    }, .{});
    const hole = size - 4;
    try node.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = hole },
        .height = .{ .px = hole },
        .background = hole_color,
        .border = .{ .width = 0, .color = hole_color, .radius = hole / 2 },
    }, .{}));
    return node;
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "AI 执行状态机：执行中(spinner/可停止) → 完成(exit 徽标+结果注入) / 失败(✨分析原因) · 组执行逐会话状态", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
