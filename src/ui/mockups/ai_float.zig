//! mockup-ai-float — AI 浮窗（展开态）设计稿复刻
//! （docs/SPEC/html/mockup-ai-float.html）。
//!
//! 结构：tbar(40) + term(620，背景终端 3 行 + .ov 压暗层 + .af 浮窗) + sbar(28)。
//! 窗口 1280×688。浮窗 600 宽锚 term 顶中央 top14：
//! grip(14) + header(43) + conversation(288，上下渐隐+滚动条) + input(112)。
//!
//! ⚠ 已知引擎问题（实机 5 轮验证，2026-10-12）：
//! 本窗口的 .af 浮窗带 `glass`（backdrop_blur 24）时，浮窗中段内容
//! （.af-c 对话流与 .ib 输入壳，恰为窗口垂直 1/3 高的带状区）会被
//! 「雾化」：AX 树布局完全正确，像素却像被浮窗自己的半透明背板盖住。
//! 逐轮排除了 overflow hidden、双阴影/backdrop_saturation、显式高度、
//! 双层 glass（.ov），稳定复现且截图逐字节不变（非瞬时合成伪影）。
//! 而同结构的 mockup-ai-exec（.ov 零尺寸未渲染、仅单块 glass）正常。
//! 待查方向：zenit glass 图层与 text 批次的排序/裁剪交互（疑似渲染
//! 引擎缺陷，非本 mockup 写法问题）。布局几何本身已逐项核对无误。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 688 };
pub const title = "mockup-ai-float";

const tok = mock.tok;

// HTML 内联色（非 :root token）
const af_bg = ui.Color.rgba(248, 255, 251, 242); // rgba(248,255,251,.95)
const hairline = ui.Color.rgba(0, 0, 0, 13); // rgba(0,0,0,.05)
const slate200 = ui.Color.rgb(226, 232, 240); // #E2E8F0
const slate50 = ui.Color.rgb(248, 250, 252); // #F8FAFC
const input_bd = ui.Color.rgb(214, 229, 220); // #D6E5DC
const dark_bg = ui.Color.rgb(0x0F, 0x17, 0x2A); // #0F172A
const dark_fg = ui.Color.rgb(226, 232, 240); // #E2E8F0
const grn_dollar = ui.Color.rgb(0x34, 0xD3, 0x99); // #34D399
const grn_deep = ui.Color.rgb(0x05, 0x96, 0x69); // #059669
const amber_deep = ui.Color.rgb(0xB4, 0x53, 0x09); // #B45309

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40：页签 on/off + 右侧图标） ──────────────────────

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

    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01 ✕", true));
    try bar.appendChild(cx.allocator, try tab(cx, "终端组: k8s-nodes ✕", false));
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
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = if (on) .{ .width = 1, .color = tok.bd, .radius = 7 } else .{ .width = 0, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    })});
}

// ── 终端区（620px：3 行背景内容 + 压暗层 + AI 浮窗） ───────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 620 },
        .direction = .column,
        .position = .relative,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .flex_shrink = 0,
    }, .{});

    const td = tok.alpha(tok.fg, 140); // .td opacity .55
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl get pods -n prod-app", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "NAME                        READY   STATUS             RESTARTS", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "backend-api-7b89f6d-x9p1r   ", .color = td },
        .{ .text = "1/2", .color = tok.alpha(tok.yel, 140) },
        .{ .text = "     ", .color = td },
        .{ .text = "CrashLoopBackOff", .color = tok.alpha(tok.red, 140) },
        .{ .text = "   ", .color = td },
        .{ .text = "14", .color = tok.alpha(tok.yel, 140) },
    }, .{}));

    // .ov 压暗层：theme.bg.35（CSS 另有 backdrop blur(3)，此处未画：
    // 35% 底色下视觉不可辨，且同窗口内多块 glass 有引擎已知问题，见文件尾注）。
    try term.appendChild(cx.allocator, try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .background = tok.alpha(tok.bg, 89),
        .z_index = 10,
    }, .{}));

    // .af AI 浮窗
    try term.appendChild(cx.allocator, try mountAIFloat(cx));
    return term;
}

// ── AI 浮窗主体（600×457，顶中央 top14） ──────────────────────────

fn mountAIFloat(cx: *ui.Cx) !*ui.Node {
    const af = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 14 }, .left = .{ .px = 340 } },
        .width = .{ .px = 600 },
        // 不设显式高度：grip14+header43+conv288+input112 自然堆叠为 457
        //（HTML .af top:14、总高 457，由子节点堆叠得出）。
        .direction = .column,
        .background = af_bg,
        .glass = .{ .backdrop_blur = 24 },
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) },
        .z_index = 20,
    }, .{
        try mountGrip(cx),
        try mountHeader(cx),
        try mountConversation(cx),
        try mountInput(cx),
    });
    return af;
}

/// .af-grip：14px 拖拽条区，底 accent.05→透明 渐变；36×4 圆角条。
fn mountGrip(cx: *ui.Cx) !*ui.Node {
    const grip = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 14 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .gradient = .{
            .from = tok.alpha(tok.acc, 13), // rgba(19,69,246,.05)
            .to = tok.alpha(tok.acc, 0),
            .direction = .vertical,
        },
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

/// .af-h：✨ + 标题 13·600 + 作用域 chip + Esc 收起。
fn mountHeader(cx: *ui.Cx) !*ui.Node {
    const header = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 43 },
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 10 },
        .border = .{ .width = 1, .color = hairline, .radius = 0, .side_widths = .{ 0, 0, 1, 0 } },
        .flex_shrink = 0,
    }, .{});
    try header.appendChild(cx.allocator, try ui.text(cx, "✨", .{ .font_size = 13 }));
    try header.appendChild(cx.allocator, try ui.text(cx, "AI 运维助手", .{
        .font_size = 13,
        .font_weight = 600,
        .color = tok.fg,
    }));
    // .scope 作用域 chip
    const scope = try ui.box(cx, .{
        .height = .{ .px = 25 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 13), // rgba(19,69,246,.05)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 31), .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try scope.appendChild(cx.allocator, try ui.text(cx, "🖥 当前会话: K8s-Node01 ▾", .{
        .font_size = 10.5,
        .font_weight = 500,
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

// ── 对话流（af-c 288px：渐隐 + 滚动条 + 气泡/执行卡/命令卡） ───────

fn mountConversation(cx: *ui.Cx) !*ui.Node {
    const conv = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 288 },
        .direction = .column,
        .position = .relative,
        .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 },
        .flex_shrink = 0,
    }, .{});

    // 滚动条（右缘 5，top 56，5×88）
    try conv.appendChild(cx.allocator, try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 56 }, .right = .{ .px = 5 } },
        .width = .{ .px = 5 },
        .height = .{ .px = 88 },
        .background = ui.Color.rgba(15, 23, 42, 41), // rgba(15,23,42,.16)
        .border = .{ .width = 0, .color = tok.fg, .radius = 3 },
        .z_index = 3,
    }, .{}));

    // 顶部渐隐 18px
    try conv.appendChild(cx.allocator, try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 } },
        .width = .fill(),
        .height = .{ .px = 18 },
        .gradient = .{
            .from = af_bg,
            .to = ui.Color.rgba(248, 255, 251, 0),
            .direction = .vertical,
        },
        .z_index = 2,
    }, .{}));
    // 底部渐隐 18px（自下而上）
    try conv.appendChild(cx.allocator, try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .bottom = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 } },
        .width = .fill(),
        .height = .{ .px = 18 },
        .gradient = .{
            .from = ui.Color.rgba(248, 255, 251, 0),
            .to = af_bg,
            .direction = .vertical,
        },
        .z_index = 2,
    }, .{}));

    // 历史回溯提示（居中 9.5px + 虚线分隔）
    const note_row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 13 },
        .direction = .row,
        .justify = .center,
        .margin = .{ .top = 0, .right = 0, .bottom = 6, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try note_row.appendChild(cx.allocator, try ui.text(cx, "⋯ 已上翻查看更多历史（12 条消息）· 新内容到达时贴底才自动跟随 ⋯", .{
        .font_size = 9.5,
        .color = tok.fg3,
    }));
    try conv.appendChild(cx.allocator, note_row);
    try conv.appendChild(cx.allocator, try dashedLine(cx));
    try conv.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 8 },
        .flex_shrink = 0,
    }, .{}));

    // 用户气泡：accent.07 底，圆角 10/10/3/10，右缩 48
    const bubble = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .no_cross_stretch = true,
        .margin = .{ .top = 0, .right = 0, .bottom = 9, .left = 48 },
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .background = tok.alpha(tok.acc, 18), // rgba(19,69,246,.07)
        .corner_radii = .{ .each = .{ 10, 10, 3, 10 } }, // 10 10 3 10（TL TR BR BL）
        .flex_shrink = 0,
    }, .{});
    try bubble.appendChild(cx.allocator, try ui.text(cx, "backend-api 有个 pod 一直 CrashLoopBackOff，帮我排查", .{
        .font_size = 12,
        .color = tok.fg,
    }));
    try conv.appendChild(cx.allocator, bubble);

    // exec 执行卡（.tr2）
    const tr2 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .top = 0, .right = 0, .bottom = 6, .left = 0 },
        .padding = .{ .left = 11, .right = 11, .top = 6, .bottom = 6 },
        .background = slate50,
        .border = .{ .width = 1, .color = slate200, .radius = 9 },
        .flex_shrink = 0,
    }, .{});
    const th = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 15 },
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 0, .right = 0, .bottom = 4, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try th.appendChild(cx.allocator, try ui.text(cx, "✓ exec · 只读 · 自动执行 (远端独立 channel)", .{
        .font_size = 10,
        .font_weight = 500,
        .color = tok.grn,
    }));
    try tr2.appendChild(cx.allocator, th);
    const tr2_l1 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 15 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try tr2_l1.appendChild(cx.allocator, try ui.text(cx, "$ kubectl describe pod backend-api-…-x9p1r | tail-20", .{
        .font_size = 10.5,
        .color = tok.fg2,
        .use_monospace_font = true,
    }));
    try tr2.appendChild(cx.allocator, tr2_l1);
    const tr2_l2 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 15 },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try tr2_l2.appendChild(cx.allocator, try ui.text(cx, "… Last State: OOMKilled · Exit Code: 137 …", .{
        .font_size = 10.5,
        .color = tok.alpha(tok.fg2, 179), // opacity .7
        .use_monospace_font = true,
    }));
    try tr2.appendChild(cx.allocator, tr2_l2);
    try conv.appendChild(cx.allocator, tr2);

    // 根因说明行
    const root_cause = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 17 },
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 4, .right = 0, .bottom = 4, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try root_cause.appendChild(cx.allocator, try ui.text(cx, "根因：", .{
        .font_size = 12,
        .font_weight = 700,
        .color = tok.fg,
    }));
    try root_cause.appendChild(cx.allocator, try ui.text(cx, "内存 limit 仅 256Mi，新版本启动峰值超限 → OOMKilled。建议提升至 512Mi：", .{
        .font_size = 12,
        .color = tok.fg,
    }));
    try conv.appendChild(cx.allocator, root_cause);

    // 命令卡（.cc）
    const cc = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .top = 4, .right = 0, .bottom = 0, .left = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.alpha(tok.red, 77), .radius = 11 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    // .wt 警示头
    const wt = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.red, 15), // rgba(220,76,63,.06)
        .flex_shrink = 0,
    }, .{});
    try wt.appendChild(cx.allocator, try ui.text(cx, "⚠ 写操作 · 修改生产集群 · 权限模式「确认后执行」要求人工确认", .{
        .font_size = 10,
        .font_weight = 500,
        .color = tok.red,
    }));
    try cc.appendChild(cx.allocator, wt);
    // .cb2 命令体（深底绿$）
    const cb2 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 31 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .background = dark_bg,
        .flex_shrink = 0,
    }, .{});
    try cb2.appendChild(cx.allocator, try ui.text(cx, "$", .{
        .font_size = 11,
        .color = grn_dollar,
        .use_monospace_font = true,
    }));
    try cb2.appendChild(cx.allocator, try ui.text(cx, " kubectl set resources deploy/backend-api -n prod-app --limits=memory=512Mi", .{
        .font_size = 11,
        .color = dark_fg,
        .use_monospace_font = true,
    }));
    try cc.appendChild(cx.allocator, cb2);
    // .ca 动作行
    const ca = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .padding = .{ .left = 12, .right = 12, .top = 7, .bottom = 7 },
        .flex_shrink = 0,
    }, .{});
    try ca.appendChild(cx.allocator, try ccButton(cx, "✓ 执行到当前会话", .primary));
    try ca.appendChild(cx.allocator, try ccButton(cx, "👥 执行到组 (4)", .green));
    try ca.appendChild(cx.allocator, try ccButton(cx, "⧉ 复制", .plain));
    try cc.appendChild(cx.allocator, ca);
    try conv.appendChild(cx.allocator, cc);
    return conv;
}

/// 虚线分隔（1px dashed rgba(0,0,0,.06)）：3px 短划 + 3px 间隔。
fn dashedLine(cx: *ui.Cx) !*ui.Node {
    const line = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .direction = .row,
        .gap = 3,
        .flex_shrink = 0,
    }, .{});
    var i: usize = 0;
    while (i < 95) : (i += 1) {
        try line.appendChild(cx.allocator, try ui.box(cx, .{
            .width = .{ .px = 3 },
            .height = .{ .px = 1 },
            .background = ui.Color.rgba(0, 0, 0, 15),
            .flex_shrink = 0,
        }, .{}));
    }
    return line;
}

const CcButtonKind = enum { primary, green, plain };

/// .bt 三态按钮：高 20 / 圆角 7 / 字 10.5·500。
fn ccButton(cx: *ui.Cx, label: []const u8, kind: CcButtonKind) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = switch (kind) {
            .primary => tok.acc,
            .green => tok.alpha(tok.grn, 20), // rgba(16,185,129,.08)
            .plain => slate50,
        },
        .border = switch (kind) {
            .primary => .{ .width = 0, .color = tok.acc, .radius = 7 },
            .green => .{ .width = 1, .color = tok.alpha(tok.grn, 64), .radius = 7 }, // rgba(16,185,129,.25)
            .plain => .{ .width = 1, .color = slate200, .radius = 7 },
        },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .font_weight = 500,
        .color = switch (kind) {
            .primary => tok.white,
            .green => grn_deep,
            .plain => tok.fg2,
        },
    }));
    return node;
}

// ── 输入区（af-in 112px：两行输入框 + 底注） ───────────────────────

fn mountInput(cx: *ui.Cx) !*ui.Node {
    const af_in = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 112 },
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 9, .bottom = 10 },
        .border = .{ .width = 1, .color = hairline, .radius = 0, .side_widths = .{ 1, 0, 0, 0 } },
        .flex_shrink = 0,
    }, .{});

    // 白色输入壳（圆角 11，边 #D6E5DC）
    const shell = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 75 },
        .direction = .column,
        .background = tok.white,
        .border = .{ .width = 1, .color = input_bd, .radius = 11 },
        .flex_shrink = 0,
    }, .{});

    // 行1：多行输入内容（min-h 40）+ 块光标
    const line1 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 4 },
        .flex_shrink = 0,
    }, .{});
    try line1.appendChild(cx.allocator, try ui.text(cx, "对比三台节点的内存占用曲线，给出是否需要扩容的建议", .{
        .font_size = 12,
        .color = tok.fg,
    }));
    try line1.appendChild(cx.allocator, try ui.text(cx, "（⌘↵ 换行 · 多行自动增高）", .{
        .font_size = 12,
        .color = tok.fg3,
    }));
    try line1.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 7 },
        .height = .{ .px = 14 },
        .background = tok.alpha(tok.fg, 204), // opacity .8
        .flex_shrink = 0,
    }, .{}));
    try shell.appendChild(cx.allocator, line1);

    // 行2：控件条（22px 图标级）
    const line2 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 33 },
        .direction = .row,
        .align_items = .center,
        .gap = 5,
        .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 7 },
        .flex_shrink = 0,
    }, .{});
    // ＋ 附加按钮
    const plus = try ui.box(cx, .{
        .width = .{ .px = 22 },
        .height = .{ .px = 22 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 1, .color = slate200, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try plus.appendChild(cx.allocator, try ui.text(cx, "＋", .{
        .font_size = 12,
        .color = tok.fg2,
    }));
    try line2.appendChild(cx.allocator, plus);
    // ✋ 权限模式 chip
    const perm = try ui.box(cx, .{
        .height = .{ .px = 21 },
        .direction = .row,
        .align_items = .center,
        .gap = 2,
        .padding = .{ .left = 6, .right = 6, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.yel, 20), // rgba(212,154,12,.08)
        .border = .{ .width = 1, .color = tok.alpha(tok.yel, 64), .radius = 6 }, // rgba(212,154,12,.25)
        .flex_shrink = 0,
    }, .{});
    try perm.appendChild(cx.allocator, try ui.text(cx, "✋", .{
        .font_size = 9.5,
        .font_weight = 600,
        .color = amber_deep,
    }));
    try perm.appendChild(cx.allocator, try ui.text(cx, "确认后执行", .{
        .font_size = 9.5,
        .font_weight = 600,
        .color = amber_deep,
    }));
    try perm.appendChild(cx.allocator, try ui.text(cx, "▾", .{
        .font_size = 9.5,
        .font_weight = 600,
        .color = amber_deep,
    }));
    try line2.appendChild(cx.allocator, perm);
    try line2.appendChild(cx.allocator, try ui.spacer(cx));

    // ◔ 上下文用量环（conic 23%）+ 23%
    const ctx = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 3,
        .flex_shrink = 0,
    }, .{});
    try ctx.appendChild(cx.allocator, try contextRing(cx));
    try ctx.appendChild(cx.allocator, try ui.text(cx, "23%", .{
        .font_size = 8.5,
        .color = tok.fg3,
    }));
    try line2.appendChild(cx.allocator, ctx);

    // 模型 chip：色点 + 短名 + ·中 ▾
    const model = try ui.box(cx, .{
        .height = .{ .px = 21 },
        .direction = .row,
        .align_items = .center,
        .gap = 3,
        .padding = .{ .left = 7, .right = 7, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 13),
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 31), .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try model.appendChild(cx.allocator, try mock.dot(cx, 6, tok.pur)); // #8B5CF6
    try model.appendChild(cx.allocator, try ui.text(cx, "sonnet-4", .{
        .font_size = 9.5,
        .font_weight = 700,
        .color = tok.fg,
    }));
    try model.appendChild(cx.allocator, try ui.text(cx, "·中", .{
        .font_size = 9.5,
        .color = tok.fg3,
    }));
    try model.appendChild(cx.allocator, try ui.text(cx, "▾", .{
        .font_size = 9.5,
        .color = tok.fg,
    }));
    try line2.appendChild(cx.allocator, model);

    // ➤ 发送按钮
    const send = try ui.box(cx, .{
        .width = .{ .px = 22 },
        .height = .{ .px = 22 },
        .align_items = .center,
        .justify = .center,
        .background = tok.acc,
        .border = .{ .width = 0, .color = tok.acc, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try send.appendChild(cx.allocator, try ui.text(cx, "➤", .{
        .font_size = 11,
        .color = tok.white,
    }));
    try line2.appendChild(cx.allocator, send);
    try shell.appendChild(cx.allocator, line2);
    try af_in.appendChild(cx.allocator, shell);

    // 底注（8.5px fg3）
    const note = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 13 },
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 4, .right = 0, .bottom = 0, .left = 2 },
        .flex_shrink = 0,
    }, .{});
    try note.appendChild(cx.allocator, try ui.text(cx, "⬡ 上下文与命令均作用于远程服务器 (10.200.1.18) · ◔环=模型窗口用量 · / 触发远程文件选择", .{
        .font_size = 8.5,
        .color = tok.fg3,
    }));
    try af_in.appendChild(cx.allocator, note);
    return af_in;
}

/// ◔ 上下文环：14² conic accent 0-23% → #E5EFEA，内孔 7² 白。
/// conic 默认 3 点钟起，rotate -90° 使起始角对齐 12 点钟（CSS conic 语义）。
fn contextRing(cx: *ui.Cx) !*ui.Node {
    const track = ui.Color.rgb(0xE5, 0xEF, 0xEA);
    const node = try ui.box(cx, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
        .align_items = .center,
        .justify = .center,
        .multi_gradient = ui.MultiGradient.fromSlice(&.{
            .{ .color = tok.acc, .position = 0.0 },
            .{ .color = tok.acc, .position = 0.23 },
            .{ .color = track, .position = 0.23 },
            .{ .color = track, .position = 1.0 },
        }, .conic),
        .rotate = -std.math.pi / 2.0,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 7 },
        .height = .{ .px = 7 },
        .background = tok.white,
        .border = .{ .width = 0, .color = tok.white, .radius = 3.5 },
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
    try bar.appendChild(cx.allocator, try ui.text(cx, "已连接 · AI 浮窗展开 · 权限: 确认后执行 · sonnet-4", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
