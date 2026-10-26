//! mockup-resize — 窄窗自适应态设计稿复刻（docs/SPEC/html/mockup-resize.html）。
//!
//! 结构：tbar(40) + main(480: 折叠侧栏 48 + term) + sbar(28)。窗口 920×576。
//! 要点：
//!  - 侧栏自动折叠为 48px 图标栏（SPEC §2.0c：<1100px 阈值触发）；
//!  - AI 边条（收起态）锚定 pane 顶部中央，三点 4px acc·55%；
//!  - 四个深色 callout 标注（①②③④）+ 顶部窗口宽 tag（wtag）；
//!  - 终端内容行首 margin-top 64px（为 ② callout 让位）。
//!
//! 与 html 的已知近似（框架能力限制）：
//!  - .strip 梯形 clip-path 无法复刻（clip_shape 三角收边非可用简单形状），
//!    以等宽浅色条 + 渐变底 + 侧边框近似，宽度与锚点位置精确。
//!  - wtag 位于窗口外(-30px)，改为贴窗口顶内侧（保留内容与样式）。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 920, .height = 576 };
pub const title = "mockup-resize";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountMain(cx),
        try mountStatusBar(cx),
    });
    // wtag：窗口宽标注（html 在窗口外 -30px；此处贴顶内侧）。
    const wtag = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } },
        .padding = .{ .left = 10, .right = 10, .top = 2, .bottom = 2 },
        .background = ui.Color.rgba(0, 0, 0, 102), // rgba(0,0,0,.4)
        .border = .{ .width = 0, .color = ui.Color.rgba(0, 0, 0, 102), .radius = 0 },
        .z_index = 60,
    }, .{});
    try wtag.appendChild(cx.allocator, try ui.text(cx, "窗口宽 920px（<1100px 阈值触发）", .{
        .font_size = 11,
        .color = ui.Color.rgb(0xE2, 0xE8, 0xF0),
        .use_monospace_font = true,
    }));
    try root.appendChild(cx.allocator, wtag);
    return root;
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

    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01 ✕", true));
    try bar.appendChild(cx.allocator, try tab(cx, "RDS-PG ✕", false));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));

    // 窄窗图标组：28×26，gap 2（html 覆写 .si 尺寸）。
    const icns = try ui.box(cx, .{
        .direction = .row,
        .gap = 2,
        .flex_shrink = 0,
    }, .{});
    try icns.appendChild(cx.allocator, try narrowIcon(cx, "⚡", false));
    try icns.appendChild(cx.allocator, try narrowIcon(cx, "⇅", false));
    try icns.appendChild(cx.allocator, try narrowIcon(cx, "✨", true));
    try icns.appendChild(cx.allocator, try narrowIcon(cx, "⚙️", false));
    try bar.appendChild(cx.allocator, icns);
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    }));
    return node;
}

fn narrowIcon(cx: *ui.Cx, icon: []const u8, accent: bool) !*ui.Node {
    const icn = try ui.box(cx, .{
        .width = .{ .px = 28 },
        .height = .{ .px = 26 },
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

// ── 主体（480px：折叠侧栏 48 + 终端） ──────────────────────────────

fn mountMain(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 480 },
        .direction = .row,
        .flex_shrink = 0,
        .overflow = .hidden,
    }, .{
        try mountCollapsedSidebar(cx),
        try mountTerm(cx),
    });
}

fn sidebarIcon(cx: *ui.Cx, icon: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 34 },
        .height = .{ .px = 34 },
        .align_items = .center,
        .justify = .center,
        .background = if (on) tok.alpha(tok.acc, 26) else ui.Color.TRANSPARENT, // rgba(19,69,246,.1)
        .border = .{ .width = 0, .color = tok.acc, .radius = 9 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 15,
        .color = if (on) tok.acc else tok.fg2,
    }));
    return node;
}

fn mountCollapsedSidebar(cx: *ui.Cx) !*ui.Node {
    const sbc = try ui.box(cx, .{
        .width = .{ .px = 48 },
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .padding = .{ .left = 0, .right = 0, .top = 8, .bottom = 8 },
        .gap = 4,
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try sbc.appendChild(cx.allocator, try sidebarIcon(cx, "🔍", false));
    try sbc.appendChild(cx.allocator, try sidebarIcon(cx, "⬡", true));
    try sbc.appendChild(cx.allocator, try sidebarIcon(cx, "⬡", false));
    try sbc.appendChild(cx.allocator, try sidebarIcon(cx, "🗄️", false));
    try sbc.appendChild(cx.allocator, try ui.spacer(cx));
    try sbc.appendChild(cx.allocator, try sidebarIcon(cx, "⇥", false));
    return sbc;
}

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .background = tok.bg,
        .overflow = .hidden,
        .min_width = 0,
    }, .{});

    // AI 边条（收起态）：顶部中央锚定，高 13，三点 4px acc 55%。
    const strip = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 } },
        .width = .{ .px = 138 },
        .height = .{ .px = 13 },
        .align_self = .center,
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .gap = 5,
        .gradient = .{ .from = ui.Color.rgba(255, 255, 255, 217), .to = tok.alpha(tok.bg, 140), .direction = .vertical },
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 56), .radius = 0, .side_widths = .{ -1, 1, 1, 1 } }, // 顶边无线
        .z_index = 5,
    }, .{});
    for (0..3) |_| {
        try strip.appendChild(cx.allocator, try mock.dot(cx, 4, tok.alpha(tok.acc, 140)));
    }
    try term.appendChild(cx.allocator, strip);

    // ① 侧栏标注（锚 .term，left 52 top 96）。
    try term.appendChild(cx.allocator, try callout(cx, "① 侧栏自动折叠为 48px（⌘B 可手动展开覆盖）", 52, 96, null));

    // 行首留白 64px（html margin-top:64px）。
    try term.appendChild(cx.allocator, try ui.box(cx, .{ .height = .{ .px = 64 }, .flex_shrink = 0 }, .{}));

    const td = tok.alpha(tok.fg, 140);
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ kubectl get pods", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "NAME                        READY   STATUS    RESTARTS", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "backend-api-7b89f6d-k4m2q   2/2     Running   0", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "worker-queue-91ca4-hn7f2    1/1     Running   0", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{}));

    // ② AI 边条标注：top 40 水平居中（left 50% - 宽/2 ≈ (920-48)/2=436 中心 → left ≈ 436-150）。
    try term.appendChild(cx.allocator, try callout(cx, "② AI 边条锚定 Pane 顶部中央，随 resize 重定位不漂移", 156, 40, null));
    // ④ 右下标注：right 16 bottom 80 → top = 480-80-高度。
    try term.appendChild(cx.allocator, try callout(cx, "④ 终端列数 96×26 实时 reflow（软换行重算）", null, 380, 16));
    return term;
}

/// 深色标注条：10px 白字，圆角 6，阴影。left/right 二选一锚定。
fn callout(cx: *ui.Cx, text: []const u8, left: ?f32, top: f32, right: ?f32) !*ui.Node {
    const node = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{
            .top = .{ .px = top },
            .left = if (left) |l| .{ .px = l } else .auto,
            .right = if (right) |r| .{ .px = r } else .auto,
        },
        .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
        .background = ui.Color.rgb(0x0F, 0x17, 0x2A),
        .border = .{ .width = 0, .color = ui.Color.rgb(0x0F, 0x17, 0x2A), .radius = 6 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = ui.Color.rgba(0, 0, 0, 64) },
        .z_index = 40,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 10,
        .color = tok.white,
    }));
    return node;
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
    // k8s-node01 · RTT 24ms（html 是两个文本节点由 gap6 分隔）。
    try bar.appendChild(cx.allocator, try ui.text(cx, "k8s-node01", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.text(cx, "· RTT 24ms", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    // ③ 状态栏右侧标注。
    try bar.appendChild(cx.allocator, try ui.text(cx, "③ 状态栏低优先级项(编码/尺寸)已自动隐藏", .{
        .font_size = 10,
        .color = tok.fg3,
    }));
    return bar;
}
