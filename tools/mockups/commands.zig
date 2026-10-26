//! mockup-commands — @ 指令菜单设计稿复刻（docs/SPEC/html/mockup-commands.html）。
//!
//! 结构：tbar(40) + term(600, 内含 absolute @ 菜单) + 注释行(25) + sbar(28)。
//! 窗口 1280×693。HTML 为唯一 ground truth。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 693 };
pub const title = "mockup-commands";

const tok = mock.tok;

// html 局部色
const c_f1f5f9 = ui.Color.rgb(0xF1, 0xF5, 0xF9); // #F1F5F9
const c_e2e8f0 = ui.Color.rgb(0xE2, 0xE8, 0xF0); // #E2E8F0
const c_tb = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountNoteBar(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40px） ─────────────────────────────────────────────

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
    // 红绿灯（预览程序原生红绿灯重叠于此）
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

    // 页签：K8s-Node01(on) / K8s-Node02(off)
    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01", true));
    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node02", false));

    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    // 右侧全局图标：⚡ ⇅ ✨(acc) ⚙️
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️"));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    // html .tab 无 gap —— "名字 ✕" 以空格衔接
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
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
    try node.appendChild(cx.allocator, try ui.text(cx, " ✕", .{ .font_size = 12, .color = if (on) tok.fg else tok.fg2 }));
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

// ── 终端区（term 600px，@ 菜单锚内） ────────────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});

    const td = tok.alpha(tok.fg, 140); // .td opacity .55
    // 行1
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ kubectl get deploy -n prod", .color = tok.fg },
    }, .{}));
    // 行2-4
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "NAME          READY   UP-TO-DATE   AVAILABLE   AGE", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "backend-api   2/2     2            2           3d", .color = td },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "worker-queue  1/1     1            1           3d", .color = td },
    }, .{}));
    // 行5：空
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    // 行6：ghost-text 行（整行 opacity .75）
    try term.appendChild(cx.allocator, try ghostTextLine(cx));
    // 行7：空
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    // 行8：输入行 @th + 块光标（accent）
    const input_row = try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true });
    try input_row.appendChild(cx.allocator, try ui.text(cx, "@", .{
        .font_size = 13, .font_weight = 600, .color = tok.acc, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.text(cx, "th", .{
        .font_size = 13, .font_weight = 700, .color = tok.acc, .use_monospace_font = true, .line_height = 1.5,
    }));
    try input_row.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 8 }, .height = .{ .px = 16 }, .background = tok.acc, .flex_shrink = 0,
    }, .{}));
    try term.appendChild(cx.allocator, input_row);

    // @ 指令菜单（absolute left 168 top 92，宽 430）
    try term.appendChild(cx.allocator, try mountAtMenu(cx));
    return term;
}

/// 行6：ghost-text 行（整行 opacity .75；mono 13 + Inter 10 附注混排）。
fn ghostTextLine(cx: *ui.Cx) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .opacity = 0.75,
        .flex_shrink = 0,
    }, .{});
    const spans = [_]mock.TermSpan{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = c_tb },
        .{ .text = "$ kubectl rollout restart deploy/", .color = tok.fg },
        .{ .text = "backend-api -n prod", .color = tok.alpha(tok.fg3, 140) },
    };
    for (spans) |span| {
        try row.appendChild(cx.allocator, try ui.text(cx, span.text, .{
            .font_size = 13, .font_weight = 400, .color = span.color,
            .use_monospace_font = true, .line_height = 1.5,
        }));
    }
    try row.appendChild(cx.allocator, try ui.text(cx, " ⇥ ghost-text 补全（历史+路径缓存，→ 接受）", .{
        .font_size = 10, .color = tok.fg3,
    }));
    return row;
}

// ── @ 指令菜单（.atmenu 430 宽） ────────────────────────────────────

fn mountAtMenu(cx: *ui.Cx) !*ui.Node {
    const menu = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 92 }, .left = .{ .px = 168 } },
        .width = .{ .px = 430 },
        .direction = .column,
        .background = ui.Color.rgba(0xFF, 0xFF, 0xFF, 245), // rgba(255,255,255,.96)
        .border = .{ .width = 0, .color = tok.bd, .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0, 0, 0, 41) }, // rgba(0,0,0,.16)
        .z_index = 50,
    }, .{});

    // 头部说明（10.5·600 fg3）
    const head = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 14, .right = 14, .top = 9, .bottom = 9 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "内置指令", .{
        .font_size = 10.5, .font_weight = 600, .color = tok.fg3,
    }));
    // @ tag（mono 10.5 acc，底 acc.08）
    const tag = try ui.box(cx, .{
        .padding = .{ .left = 7, .right = 7, .top = 1, .bottom = 1 },
        .background = tok.alpha(tok.acc, 20), // rgba(19,69,246,.08)
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
    }, .{});
    try tag.appendChild(cx.allocator, try ui.text(cx, "@", .{
        .font_size = 10.5, .color = tok.acc, .use_monospace_font = true,
    }));
    try head.appendChild(cx.allocator, tag);
    try head.appendChild(cx.allocator, try ui.text(cx, "仅在提示符行首键入生效 · @ 前有空格/文本不触发 · 不发送远端", .{
        .font_size = 10.5, .font_weight = 600, .color = tok.fg3,
    }));
    try menu.appendChild(cx.allocator, head);

    // 条目（sel 行底 acc.07）
    try menu.appendChild(cx.allocator, try atMenuItem(cx, "🎨", "@theme", "会话主题切换", "@theme dark-pro", true));
    try menu.appendChild(cx.allocator, try atMenuItem(cx, "🕐", "@ts", "时间戳侧栏开关", "@ts on", false));

    // 底部计数 + 快捷键（spec 实际渲染为两行紧凑布局：行1=键帽+首字，
    // 行2=「14 条」+ 各组第二字纵排于键帽下方）
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .start,
        .gap = 12,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const left_col = try ui.box(cx, .{
        .direction = .column,
        .gap = 4,
        .flex_shrink = 0,
    }, .{});
    try left_col.appendChild(cx.allocator, try ui.text(cx, "共 2 条匹配 · 键入 @ 单独查看全部", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try left_col.appendChild(cx.allocator, try ui.text(cx, "14 条", .{
        .font_size = 10, .color = tok.fg3,
    }));
    try foot.appendChild(cx.allocator, left_col);
    try foot.appendChild(cx.allocator, try kbdGroup(cx, "↑↓", "选", "择"));
    try foot.appendChild(cx.allocator, try kbdGroup(cx, "→", "采", "纳"));
    try foot.appendChild(cx.allocator, try kbdGroup(cx, "↵", "执", "行"));
    try foot.appendChild(cx.allocator, try kbdGroup(cx, "@@", "转义字面", "@"));
    try menu.appendChild(cx.allocator, foot);
    return menu;
}

fn atMenuItem(cx: *ui.Cx, icon: []const u8, cmd: []const u8, desc: []const u8, example: []const u8, selected: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 11,
        .padding = .{ .left = 14, .right = 14, .top = 7, .bottom = 7 },
        .background = if (selected) tok.alpha(tok.acc, 18) else ui.Color.TRANSPARENT, // rgba(19,69,246,.07)
        .flex_shrink = 0,
    }, .{});
    // 图标框 24×24 圆角 6，底 acc.06
    const ic = try ui.box(cx, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .align_items = .center,
        .justify = .center,
        .background = tok.alpha(tok.acc, 15),
        .border = .{ .width = 0, .color = tok.acc, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 12, .color = tok.fg }));
    try row.appendChild(cx.allocator, ic);
    // 指令列：宽 96，mono 12·600 accent
    const cmd_col = try ui.box(cx, .{
        .width = .{ .px = 96 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{});
    try cmd_col.appendChild(cx.allocator, try ui.text(cx, cmd, .{
        .font_size = 12, .font_weight = 600, .color = tok.acc, .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, cmd_col);
    try row.appendChild(cx.allocator, try ui.text(cx, desc, .{ .font_size = 11.5, .color = tok.fg2 }));
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    try row.appendChild(cx.allocator, try ui.text(cx, example, .{
        .font_size = 10, .color = tok.fg3, .use_monospace_font = true,
    }));
    return row;
}

/// kbd 快捷键组（spec 紧凑换行布局）：行1 = 键帽 + 首字；行2 = 次字（键帽下方）。
fn kbdGroup(cx: *ui.Cx, key: []const u8, line1: []const u8, line2: []const u8) !*ui.Node {
    const group = try ui.box(cx, .{
        .direction = .column,
        .gap = 4,
        .flex_shrink = 0,
    }, .{});
    const top = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 4 }, .{});
    const key_box = try ui.box(cx, .{
        .padding = .{ .left = 5, .right = 5, .top = 1, .bottom = 1 },
        .background = c_f1f5f9,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 4 },
    }, .{});
    try key_box.appendChild(cx.allocator, try ui.text(cx, key, .{
        .font_size = 10, .color = tok.fg3, .use_monospace_font = true,
    }));
    try top.appendChild(cx.allocator, key_box);
    try top.appendChild(cx.allocator, try ui.text(cx, line1, .{
        .font_size = 10, .color = tok.fg3,
    }));
    try group.appendChild(cx.allocator, top);
    try group.appendChild(cx.allocator, try ui.text(cx, line2, .{
        .font_size = 10, .color = tok.fg3,
    }));
    return group;
}

// ── 注释行（term 与 sbar 之间，总高 25） ────────────────────────────

fn mountNoteBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 25 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 6 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try ui.text(cx, "键入 @th 实时过滤 → @theme 选中后参数候选：Sauber Light✓全局 · Dark Pro · Solarized Dark · Dracula · 生产警示·红", .{
        .font_size = 10, .color = tok.fg2,
    }));
    return bar;
}

// ── 状态栏（sbar 28px） ─────────────────────────────────────────────

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
    // "已连接&nbsp;|&nbsp; 补全: …"（nbsp 以 U+00A0 呈现）
    try bar.appendChild(cx.allocator, try ui.text(cx, "已连接\u{00A0}\u{00A0}|\u{00A0}\u{00A0}补全: 开 (App 级 · Tab 透传远端，采纳用右方向键)", .{
        .font_size = 11, .color = tok.fg2,
    }));
    return bar;
}
