//! ZeroWork mockup 视图共享层（基建，仅由集成者维护）。
//!
//! 作用：
//!  - 引用正式 UI 层的 SPEC §2.0 设计 token（与 HTML :root 一一对应）；
//!  - 提供 §0 控件库规格的通用小部件（主/次按钮、开关、chip、徽标、分隔线…）；
//!  - 提供模态背板 / 窗口卡片包装，供各 mockup 视图复用。
//!
//! 约束：本文件是共享文件，子智能体不得修改；需要扩展时在自己的
//! mockup 文件内本地定义。数据一律由调用方传入，本层不持有状态。
//!
//! 用法（每个 mockup 视图的固定骨架）：
//! ```zig
//! const std = @import("std");
//! const ui = @import("ui");
//! const mock = @import("common.zig");
//!
//! pub const window_size = .{ .width = 1280, .height = 660 };
//! pub const title = "mockup-main";
//!
//! pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
//!     return mock.windowCard(cx, window_size.width, window_size.height, mock.winChildren(.{...}));
//! }
//! ```

const std = @import("std");
const ui = @import("ui");

// ── 设计 token（SPEC §2.0，与效果图 :root 一致） ─────────────────────

pub const tok = @import("design_tokens").tok;

// ── 文本便捷构造（ui.text 的属性风格包一层常用默认值） ───────────────

pub fn t(cx: *ui.Cx, content: []const u8, props: anytype) !*ui.Node {
    return ui.text(cx, content, props);
}

/// 等宽文本便捷构造（mono 场景字 11-12）。
pub fn monoText(cx: *ui.Cx, content: []const u8, props: anytype) !*ui.Node {
    var p = props;
    p.use_monospace_font = true;
    return ui.text(cx, content, p);
}

// ── 小部件（§0 控件库规格） ──────────────────────────────────────────

/// 状态点：直径 size，颜色 color。
pub fn dot(cx: *ui.Cx, size: f32, color: ui.Color) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .background = color,
        .border = .{ .width = 0, .color = color, .radius = size / 2 },
        .flex_shrink = 0,
    }, .{});
}

/// 状态栏垂直分隔：1×14。
pub fn vsep(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = 1 },
        .height = .{ .px = 14 },
        .background = tok.bd,
        .margin = .{ .top = 0, .right = 6, .bottom = 0, .left = 6 },
        .flex_shrink = 0,
    }, .{});
}

/// 水平分隔线：高度 1，左右内缩 inset。
pub fn hline(cx: *ui.Cx, inset: f32) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .margin = .{ .top = 0, .right = inset, .bottom = 0, .left = inset },
        .background = tok.bd,
        .flex_shrink = 0,
    }, .{});
}

/// 徽标：高 16，圆角 4-5，字 9·600，语义色 10% 底。
pub fn badge(cx: *ui.Cx, label: []const u8, color: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 16 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 0, .bottom = 0 },
        .background = tok.alpha(color, 26), // 10%
        .border = .{ .width = 0, .color = color, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 9,
        .font_weight = 600,
        .color = color,
    }));
    return node;
}

/// chip 下拉：高 26，圆角 7，字 10.5，后缀 " ▾"，底 acc.05 边 acc.12。
pub fn chip(cx: *ui.Cx, label: []const u8, color: ui.Color) !*ui.Node {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s} ▾", .{label}) catch label;
    const node = try ui.box(cx, .{
        .height = .{ .px = 26 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 9, .top = 0, .bottom = 0 },
        .background = tok.alpha(color, 13), // 5%
        .border = .{ .width = 1, .color = tok.alpha(color, 31), .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 10.5,
        .color = color,
    }));
    return node;
}

/// 主按钮：高 34 / 圆角 8 / padding 9×26 / 渐变 acc→#2563EB / 字 12.5·600。
/// disabled=true 时 40% 透明。
pub fn primaryButton(cx: *ui.Cx, label: []const u8, disabled: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 26, .right = 26, .top = 0, .bottom = 0 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .horizontal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .opacity = if (disabled) 0.4 else 1.0,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .font_weight = 600,
        .color = tok.white,
    }));
    return node;
}

/// 次按钮：高 34 / 圆角 8 / 底 #F1F5F9 / 边 1px --bd / 字 12。
pub fn secondaryButton(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 26, .right = 26, .top = 0, .bottom = 0 },
        .background = tok.btn_sec_bg,
        .border = .{ .width = 1, .color = tok.setbd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .color = tok.fg2,
    }));
    return node;
}

/// 危险按钮（主按钮的红色变体，conflict/危险项用）。
pub fn dangerButton(cx: *ui.Cx, label: []const u8, filled: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 26, .right = 26, .top = 0, .bottom = 0 },
        .background = if (filled) tok.red else tok.alpha(tok.red, 13),
        .border = .{ .width = if (filled) 0 else 1, .color = tok.alpha(tok.red, 77), .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .font_weight = 600,
        .color = if (filled) tok.white else tok.red,
    }));
    return node;
}

/// 输入框静态外观：高 32 / 圆角 8 / 边 1px --bd / 字 12。
/// 仅复刻布局外观；焦点 ring 属交互态，静态稿不画。
pub fn inputShell(cx: *ui.Cx, placeholder: []const u8, value: []const u8, mono_font: bool, width: ?f32) !*ui.Node {
    _ = placeholder;
    const node = try ui.box(cx, .{
        .width = if (width) |w| .{ .px = w } else .fill(),
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    if (value.len > 0) {
        try node.appendChild(cx.allocator, try ui.text(cx, value, .{
            .font_size = 12,
            .color = tok.fg,
            .use_monospace_font = mono_font,
        }));
    }
    return node;
}

/// 开关：34×19 / 圆点 15 / on=accent off=#CBD5E1。
pub fn toggle(cx: *ui.Cx, on: bool) !*ui.Node {
    const track = try ui.box(cx, .{
        .width = .{ .px = 34 },
        .height = .{ .px = 19 },
        .direction = .row,
        .align_items = .center,
        .justify = if (on) .end else .start,
        .padding = .{ .left = 2, .right = 2, .top = 0, .bottom = 0 },
        .background = if (on) tok.acc else tok.off_dot,
        .border = .{ .width = 0, .color = tok.acc, .radius = 9.5 },
        .flex_shrink = 0,
    }, .{});
    try track.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .background = tok.white,
        .border = .{ .width = 0, .color = tok.white, .radius = 7.5 },
    }, .{}));
    return track;
}

/// 复选框：14²，勾选态 accent 底 + 白勾。
pub fn checkbox(cx: *ui.Cx, checked: bool) !*ui.Node {
    const box_node = try ui.box(cx, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
        .align_items = .center,
        .justify = .center,
        .background = if (checked) tok.acc else tok.white,
        .border = .{ .width = 1, .color = if (checked) tok.acc else tok.bd, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    if (checked) {
        try box_node.appendChild(cx.allocator, try ui.text(cx, "✓", .{
            .font_size = 10,
            .font_weight = 600,
            .color = tok.white,
        }));
    }
    return box_node;
}

/// 单选圆点：14² 空心/实心。
pub fn radio(cx: *ui.Cx, checked: bool) !*ui.Node {
    const outer = try ui.box(cx, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
        .align_items = .center,
        .justify = .center,
        .background = tok.white,
        .border = .{ .width = 1, .color = if (checked) tok.acc else tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    if (checked) {
        try outer.appendChild(cx.allocator, try dot(cx, 6, tok.acc));
    }
    return outer;
}

/// 终端行 span：一段文本 + 颜色/字重。
pub const TermSpan = struct {
    text: []const u8,
    color: ui.Color = tok.fg,
    weight: u16 = 400,
};

/// 终端行（.ln）：高 20，mono 13，行高 1.5，彩色 span 顺序拼接。
/// `input=true` 时画输入行高亮（acc.06 底 + 左缘 3px accent + 圆角 3 + 块光标）。
/// span 间零间距：mono 字体自然衔接。
pub fn termLine(cx: *ui.Cx, spans: []const TermSpan, opts: struct {
    input: bool = false,
    cursor: bool = false,
}) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 20 },
        .direction = .row,
        .align_items = .center,
        .padding = if (opts.input) .{ .left = 3, .right = 0, .top = 0, .bottom = 0 } else .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .background = if (opts.input) tok.alpha(tok.acc, 15) else ui.Color.TRANSPARENT,
        .inset_shadows = if (opts.input) ui.InsetShadowList.of(&.{.{ .color = tok.acc, .blur = 0, .offset_x = 3, .offset_y = 0 }}) else null,
        .border = if (opts.input) .{ .width = 0, .color = tok.acc, .radius = 3 } else null,
        .flex_shrink = 0,
    }, .{});
    for (spans) |span| {
        try row.appendChild(cx.allocator, try ui.text(cx, span.text, .{
            .font_size = 13,
            .font_weight = span.weight,
            .color = span.color,
            .use_monospace_font = true,
            .line_height = 1.5,
        }));
    }
    if (opts.cursor) {
        try row.appendChild(cx.allocator, try ui.box(cx, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 16 },
            .background = tok.fg,
            .flex_shrink = 0,
        }, .{}));
    }
    return row;
}

/// 多行终端文本便捷构造：spans 为多行，每行一个 TermSpan 数组。
pub fn termBlock(cx: *ui.Cx, comptime lines: []const []const TermSpan) !*ui.Node {
    const col = try ui.box(cx, .{ .width = .fill(), .direction = .column }, .{});
    inline for (lines) |line| {
        try col.appendChild(cx.allocator, try termLine(cx, line, .{}));
    }
    return col;
}

// ── 窗口卡片与模态背板 ─────────────────────────────────────────────

/// 效果图窗口根：预览窗口本身就是 .win/.bk 卡片，视图直接铺满窗口。
/// 圆角与桌面背景由原生窗口提供，这里只给出内容根（方向 column）。
pub fn windowRoot(cx: *ui.Cx, body: anytype) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .background = tok.bg,
        .overflow = .hidden,
    }, body);
}

/// 模态背板：rgba(0,0,0,.25) + blur(8)（设置/连接向导）。
/// 底层挂 children（一般是被压暗的主窗口内容），上层为模态卡片。
/// blur 由 glass 参数实现。
pub fn modalBackdrop(cx: *ui.Cx, children: anytype) !*ui.Node {
    return ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(0, 0, 0, 64),
        .glass = .{ .backdrop_blur = 8 },
    }, children);
}

/// 会话内浮层背板：theme.bg.35 + blur(3)。
pub fn sessionOverlayBackdrop(cx: *ui.Cx, children: anytype) !*ui.Node {
    return ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = tok.alpha(tok.bg, 89), // 35%
        .glass = .{ .backdrop_blur = 3 },
    }, children);
}

/// 浮层卡片通用外观：圆角 12 + 白底 + 阴影。
pub fn overlayCard(cx: *ui.Cx, w: f32, children: anytype) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = w },
        .direction = .column,
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 12 },
        .shadow = .{ .blur = 28, .offset_y = 10, .color = ui.Color.rgba(15, 23, 42, 70) },
    }, children);
}

/// 弹出菜单容器：宽 230-250 / 圆角 12 / 白底 / 阴影。
pub fn menuShell(cx: *ui.Cx, w: f32, children: anytype) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = w },
        .direction = .column,
        .padding = .{ .left = 6, .right = 6, .top = 6, .bottom = 6 },
        .background = tok.white,
        .border = .{ .width = 1, .color = tok.bd, .radius = 12 },
        .shadow = .{ .blur = 24, .offset_y = 8, .color = ui.Color.rgba(15, 23, 42, 90) },
    }, children);
}

/// 菜单头部说明：10px fg3。
pub fn menuHeader(cx: *ui.Cx, icon: []const u8, text: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
    }, .{});
    try row.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 13, .color = tok.fg2 }));
    try row.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 10,
        .color = tok.fg3,
    }));
    return row;
}

/// 菜单项：高 30，icon16+gap9，右侧可加快捷键注 10.5 fg3；danger 红字。
pub fn menuItem(cx: *ui.Cx, icon: []const u8, label: []const u8, shortcut: ?[]const u8, danger: bool, selected: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = if (selected) tok.alpha(tok.acc, 13) else ui.Color.rgba(0, 0, 0, 0),
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
    }, .{});
    try row.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 13,
        .color = if (danger) tok.red else tok.fg2,
    }));
    try row.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .color = if (danger) tok.red else tok.fg,
    }));
    try row.appendChild(cx.allocator, try ui.spacer(cx));
    if (shortcut) |hint| {
        try row.appendChild(cx.allocator, try ui.text(cx, hint, .{
            .font_size = 10.5,
            .color = tok.fg3,
        }));
    }
    return row;
}

/// 菜单分隔线：1px 内缩 8。
pub fn menuSeparator(cx: *ui.Cx) !*ui.Node {
    return hline(cx, 8);
}

// ── 主窗口静态骨架件（多个 mockup 的底层背景） ─────────────────────

/// 标题栏 + 页签条静态复刻（40px，含红绿灯位、页签、右上图标）。
/// 供 modal 类 mockup 做底层压暗背景。
pub fn staticTitleBar(cx: *ui.Cx, tabs: []const []const u8, active_tab: usize) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 0, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
    }, .{});
    // 红绿灯组 12px 圆 gap8（由 App 原生绘制，这里画占位点）
    for ([_]ui.Color{ ui.Color.rgb(0xFF, 0x5F, 0x57), ui.Color.rgb(0xFF, 0xBD, 0x2E), ui.Color.rgb(0x28, 0xC8, 0x40) }) |c| {
        try bar.appendChild(cx.allocator, try dot(cx, 12, c));
    }
    const gap = try ui.box(cx, .{ .width = .{ .px = 2 } }, .{});
    try bar.appendChild(cx.allocator, gap);
    for (tabs, 0..) |name, index| {
        const on = index == active_tab;
        const tab = try ui.box(cx, .{
            .height = .{ .px = 28 },
            .direction = .row,
            .align_items = .center,
            .gap = 6,
            .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
            .background = if (on) tok.bg else ui.Color.rgba(0, 0, 0, 0),
            .border = if (on) .{ .width = 1, .color = tok.bd, .radius = 7 } else .{ .width = 0, .color = tok.bd, .radius = 7 },
            .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        }, .{});
        try tab.appendChild(cx.allocator, try dot(cx, 6, tok.grn));
        try tab.appendChild(cx.allocator, try ui.text(cx, name, .{
            .font_size = 12,
            .font_weight = if (on) 500 else 400,
            .color = if (on) tok.fg else tok.fg2,
        }));
        try tab.appendChild(cx.allocator, try ui.text(cx, "✕", .{
            .font_size = 9,
            .color = tok.fg3,
        }));
        try bar.appendChild(cx.allocator, tab);
    }
    try bar.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 6 },
    }, .{try ui.text(cx, "+", .{ .font_size = 14, .color = tok.fg3 })}));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    // 右侧全局图标
    for ([_][]const u8{ "⚡", "⇅", "✨", "⚙️" }) |icon| {
        const icn = try ui.box(cx, .{
            .width = .{ .px = 30 },
            .height = .{ .px = 28 },
            .align_items = .center,
            .justify = .center,
            .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        }, .{});
        try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
            .font_size = 14,
            .color = if (std.mem.eql(u8, icon, "✨")) tok.acc else tok.fg2,
        }));
        try bar.appendChild(cx.allocator, icn);
    }
    return bar;
}

/// 终端区静态示意（供压暗背景/搜索等 mockup 底层）：浅底 + 若干示例行。
pub fn staticTerminal(cx: *ui.Cx, prompt_lines: []const []const u8) !*ui.Node {
    const pane = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .background = tok.bg,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .overflow = .hidden,
    }, .{});
    for (prompt_lines) |line| {
        try pane.appendChild(cx.allocator, try ui.text(cx, line, .{
            .font_size = 13,
            .color = tok.fg,
            .use_monospace_font = true,
            .line_height = 1.5,
        }));
    }
    return pane;
}

/// 状态栏静态复刻（28px 底 stbg）。
pub fn staticStatusBar(cx: *ui.Cx, chain: []const u8) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .background = tok.stbg,
        .border = .{ .width = 0, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
    }, .{});
    try bar.appendChild(cx.allocator, try dot(cx, 6, tok.grn));
    try bar.appendChild(cx.allocator, try ui.text(cx, chain, .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "UTF-8", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "120×36", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "⬡ ProxyJump", .{ .font_size = 11, .color = tok.acc }));
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    return bar;
}
