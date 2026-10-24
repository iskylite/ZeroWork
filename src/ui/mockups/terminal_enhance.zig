//! mockup-terminal-enhance — 终端增强态设计稿复刻
//! (docs/SPEC/html/mockup-terminal-enhance.html)。
//!
//! 结构：tbar(40) + hist(34 回溯条) + tw2(520: gutter 66 + term) + sbar(28)。
//! 窗口 1280×622。要点：
//!  - 时间戳 gutter：宽 66，右对齐 HH:mm:ss 9.5px fg3，hot 行 acc·600；
//!  - 行间 1px rgba(0,0,0,.04) 分隔（SPEC §2）；
//!  - ⌥ 矩形块选高亮与浮注只画在 .term 内（不覆盖 gutter）；
//!  - 输入行高亮 acc.06 + 左缘 3px accent（common.termLine）。
//!
//! 与 html 的已知近似（框架能力限制）：
//!  - gutter 右缘 1px dashed --bd 以 1px 实线近似（Border 无 dash 样式）。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 622 };
pub const title = "mockup-terminal-enhance";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountHistoryBar(cx),
        try mountBody(cx),
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

    // 单页签（on）：bg 底 + 描边 + 阴影，文本 "K8s-Node01 ✕"。
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

// ── 历史回溯条（hist 34px） ────────────────────────────────────────

fn mountHistoryBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .gap = 12,
        .background = ui.Color.rgba(15, 23, 42, 235), // rgba(15,23,42,.92)
        .flex_shrink = 0,
    }, .{});

    // 📜 历史回溯模式 · 只读
    const hb = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 3, .bottom = 3 },
        .background = ui.Color.rgba(255, 255, 255, 31), // rgba(255,255,255,.12)
        .border = .{ .width = 0, .color = ui.Color.rgba(255, 255, 255, 31), .radius = 5 },
        .flex_shrink = 0,
    }, .{});
    try hb.appendChild(cx.allocator, try ui.text(cx, "📜 历史回溯模式 · 只读", .{
        .font_size = 10.5,
        .font_weight = 500,
        .color = ui.Color.rgb(0xF5, 0x9E, 0x0B),
    }));
    try bar.appendChild(cx.allocator, hb);

    try bar.appendChild(cx.allocator, try mono10_5(cx, "13:58:02"));

    // 拖拽轨道：flex1 高 4，74% 填充 + 白色手柄。
    const scrub = try ui.box(cx, .{
        .flex = 1,
        .height = .{ .px = 4 },
        .background = ui.Color.rgba(255, 255, 255, 38), // rgba(255,255,255,.15)
        .border = .{ .width = 0, .color = ui.Color.rgba(255, 255, 255, 38), .radius = 2 },
        .overflow = .hidden,
        .flex_shrink = 1,
        .min_width = 0,
    }, .{});
    const fill = try ui.box(cx, .{
        // 74% of scrub ≈ 808px（1280 - 固定文本项 - gaps）。
        .width = .{ .px = 598 },
        .height = .fill(),
        .background = tok.acc,
        .border = .{ .width = 0, .color = tok.acc, .radius = 2 },
        .flex_shrink = 0,
    }, .{});
    try scrub.appendChild(cx.allocator, fill);
    try bar.appendChild(cx.allocator, scrub);

    try bar.appendChild(cx.allocator, try mono10_5(cx, "14:22:05 (现在)"));

    // 尾注是一个 span（内含 <b>ESC</b>）：打包成无 gap 的 row，防止被 bar gap 撑爆截断。
    const tail = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try tail.appendChild(cx.allocator, try ui.text(cx, "拖动回放 · 可选择复制 · ", .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    try tail.appendChild(cx.allocator, try ui.text(cx, "ESC", .{
        .font_size = 10.5,
        .font_weight = 700,
        .color = tok.white,
    }));
    try tail.appendChild(cx.allocator, try ui.text(cx, " 返回实时流", .{
        .font_size = 10.5,
        .color = tok.fg3,
    }));
    try bar.appendChild(cx.allocator, tail);

    // 白色手柄：绝对定位于回溯条（left = pad14+hb109.7+12+tm40.9+12 + 74%·scrub808 ≈ 781，居中 17-6）。
    const st = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 11 }, .left = .{ .px = 781 } },
        .width = .{ .px = 12 },
        .height = .{ .px = 12 },
        .background = tok.white,
        .border = .{ .width = 0, .color = tok.white, .radius = 6 },
        .shadow = .{ .blur = 4, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 102) },
        .z_index = 10,
    }, .{});
    try bar.appendChild(cx.allocator, st);
    return bar;
}

fn mono10_5(cx: *ui.Cx, content: []const u8) !*ui.Node {
    return ui.text(cx, content, .{
        .font_size = 10.5,
        .color = tok.fg3,
        .use_monospace_font = true,
    });
}

// ── 主体（tw2 520px：gutter 66 + term） ─────────────────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 520 },
        .direction = .row,
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{
        try mountGutter(cx),
        try mountTerm(cx),
    });
}

fn gutterLine(cx: *ui.Cx, stamp: []const u8, hot: bool) !*ui.Node {
    const gl = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 20 },
        .direction = .row,
        .justify = .end,
        .align_items = .center,
        .padding = .{ .left = 0, .right = 8, .top = 0, .bottom = 0 },
        // SPEC §2：行间分隔 1px rgba(0,0,0,.04)（html 未画，视觉近无）。
        .border = .{ .width = 1, .color = ui.Color.rgba(0, 0, 0, 10), .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try gl.appendChild(cx.allocator, try ui.text(cx, stamp, .{
        .font_size = 9.5,
        .font_weight = if (hot) 600 else 400,
        .color = if (hot) tok.acc else tok.fg3,
        .use_monospace_font = true,
    }));
    return gl;
}

fn mountGutter(cx: *ui.Cx) !*ui.Node {
    const gut = try ui.box(cx, .{
        .width = .{ .px = 66 },
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 0 },
        .background = tok.alpha(tok.bd, 46), // rgba(207,229,216,.18)
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } }, // dashed→实线近似
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{});
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:55", false));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:55", false));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:56", true));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:56", true));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:56", true));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:56", true));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:21:57", true));
    try gut.appendChild(cx.allocator, try gutterLine(cx, "14:22:05", false));

    // gcap：时间戳列 / 不参与复制 / @ts 开关（9px fg3 居中，行高 1.5）。
    const cap = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .align_items = .center,
        .padding = .{ .left = 6, .right = 6, .top = 12, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    for ([_][]const u8{ "时间戳列", "不参与复制", "@ts 开关" }) |line| {
        try cap.appendChild(cx.allocator, try ui.text(cx, line, .{
            .font_size = 9,
            .color = tok.fg3,
            .line_height = 1.5,
        }));
    }
    try gut.appendChild(cx.allocator, cap);
    return gut;
}

const td = tok.alpha(tok.fg, 140); // .td opacity .55

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
        .overflow = .hidden,
        .min_width = 0,
    }, .{});
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl top pods -n prod-app --sort-by=memory", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "NAME                           CPU(cores)   MEMORY(bytes)", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "backend-api-k4m2q              187m          412Mi", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "backend-api-x9p1r              ", .color = td },
        .{ .text = "342m", .color = tok.yel },
        .{ .text = "          ", .color = td },
        .{ .text = "298Mi", .color = tok.yel },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "worker-queue-hn7f2             95m           187Mi", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "celery-beat-mv3kx              12m           64Mi", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "monitor-agent-q2z8p            44m           96Mi", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));

    // ⌥ 矩形块选（只在 .term 坐标系内，不覆盖 gutter）。
    const blk = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 48 }, .left = .{ .px = 11 } },
        .width = .{ .px = 296 },
        .height = .{ .px = 100 },
        .background = tok.alpha(tok.acc, 46), // --sel rgba(19,69,246,.18)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 128), .radius = 2 }, // --selbd .5
        .flex_shrink = 0,
    }, .{});
    try term.appendChild(cx.allocator, blk);

    // 块选浮注。
    const seln = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 96 }, .left = .{ .px = 330 } },
        .padding = .{ .left = 9, .right = 9, .top = 3, .bottom = 3 },
        .background = ui.Color.rgb(0x0F, 0x17, 0x2A),
        .border = .{ .width = 0, .color = ui.Color.rgb(0x0F, 0x17, 0x2A), .radius = 5 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = ui.Color.rgba(0, 0, 0, 64) },
        .flex_shrink = 0,
    }, .{});
    try seln.appendChild(cx.allocator, try ui.text(cx, "⌥ 矩形块选 · 仅复制选中列, 不带时间戳", .{
        .font_size = 10,
        .color = tok.white,
    }));
    try term.appendChild(cx.allocator, seln);
    return term;
}

// ── 状态栏（28px） ─────────────────────────────────────────────────

fn kbd(cx: *ui.Cx, label: []const u8, mono_font: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 5, .right = 5, .top = 1, .bottom = 1 },
        .background = tok.btn_sec_bg, // #F1F5F9
        .border = .{ .width = 1, .color = tok.setbd, .radius = 4 }, // #E2E8F0
        .flex_shrink = 0,
    }, .{});
    // ⌥(U+2325) 在等宽替换字体中缺字形（渲染成 ⌐），改用 UI 字体。
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10,
        .color = tok.fg2,
        .use_monospace_font = mono_font,
    }));
    return node;
}

/// kbd + 后缀说明文本打包为无 gap 的 row（html 中是同一 span 内空格分隔）。
fn kbdItem(cx: *ui.Cx, key: []const u8, key_mono: bool, rest: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try kbd(cx, key, key_mono));
    try row.appendChild(cx.allocator, try ui.text(cx, rest, .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return row;
}

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
    try bar.appendChild(cx.allocator, try kbdItem(cx, "@ts", true, " 时间戳(左列, 与命令对齐)"));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try kbdItem(cx, "⌥+拖拽", false, " 块选择"));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try kbdItem(cx, "@log", true, " 历史回溯"));
    try bar.appendChild(cx.allocator, try ui.text(cx, "|", .{ .font_size = 11, .color = tok.fg2 }));
    // 双击 选词 · 三击 选逻辑行
    const item4 = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try item4.appendChild(cx.allocator, try kbd(cx, "双击", false));
    try item4.appendChild(cx.allocator, try ui.text(cx, " 选词 · ", .{ .font_size = 11, .color = tok.fg2 }));
    try item4.appendChild(cx.allocator, try kbd(cx, "三击", false));
    try item4.appendChild(cx.allocator, try ui.text(cx, " 选逻辑行", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, item4);
    return bar;
}
