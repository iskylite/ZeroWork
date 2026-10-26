//! mockup-settings-ai — 设置 · AI 辅助页（docs/SPEC/html/mockup-settings-ai.html）。
//!
//! 结构：背板 1280×840 + 居中模态 860×716（Nav 190 + 内容区 + 底栏）。
//! Provider 手风琴卡：展开卡（Anthropic 默认）含 kv 行 + 模型表
//! grid 140/1fr/46/56/34；折叠卡单行 + ▸。
//! 所有尺寸/颜色逐条对照 HTML CSS。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 840 };
pub const title = "mockup-settings-ai";

const tok = mock.tok;

// ── 设置系局部 token ────────────────────────────────────────────────

const backdrop = ui.Color.rgb(0x4C, 0x4C, 0x4C);
const modal_bg = ui.Color.rgb(0xF7, 0xFF, 0xFB);
const nav_bg = tok.setnav;
const nav_bd = ui.Color.rgb(0xE4, 0xF1, 0xE8);
const nav_t_sep = ui.Color.rgb(0xE4, 0xF1, 0xE8);
const pv_bd = ui.Color.rgb(0xE3, 0xEE, 0xE7); // .pv 边
const pv_detail_sep = ui.Color.rgb(0xEE, 0xF5, 0xF0); // .pv-detail border-top
const mth_sep = ui.Color.rgb(0xEE, 0xF5, 0xF0); // .mth border-bottom
const mtr_sep = ui.Color.rgb(0xF4, 0xFA, 0xF6); // .mtr border-bottom
const chip_bg = ui.Color.rgb(0xF4, 0xFB, 0xF7);
const addb_bd = ui.Color.rgb(0xC9, 0xDC, 0xD0); // .addb dashed 边
const row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // .row border-bottom
const ftr_sep = ui.Color.rgb(0xE9, 0xF3, 0xEC); // .ftr border-top
const grn_txt = ui.Color.rgb(0x05, 0x96, 0x69); // #059669
const gray_st_bg = ui.Color.rgb(0xF1, 0xF5, 0xF9); // 可用/未配置徽标底

// ── 模态框架 ────────────────────────────────────────────────────────

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .background = backdrop,
        .overflow = .hidden,
    }, .{});
    const md = try ui.box(cx, .{
        .width = .{ .px = 860 },
        .height = .{ .px = 716 },
        .direction = .row,
        .background = modal_bg,
        .border = .{ .width = 0, .color = modal_bg, .radius = 14 },
        .shadow = .{ .blur = 70, .offset_y = 30, .color = ui.Color.rgba(0, 0, 0, 64) },
        .overflow = .hidden,
        .overflow_hidden = true,
        .flex_shrink = 0,
    }, .{
        try mountNav(cx),
        try mountContent(cx),
    });
    try root.appendChild(cx.allocator, md);
    return root;
}

// ── Nav（190px，on=AI 辅助） ────────────────────────────────────────

fn mountNav(cx: *ui.Cx) !*ui.Node {
    const nav = try ui.box(cx, .{
        .width = .{ .px = 190 },
        .height = .fill(),
        .direction = .column,
        .background = nav_bg,
        .border = .{ .width = 1, .color = nav_bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .padding = .{ .left = 0, .right = 0, .top = 20, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});

    const nav_t = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 20, .right = 20, .top = 0, .bottom = 16 },
        .border = .{ .width = 1, .color = nav_t_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 8 },
        .flex_shrink = 0,
    }, .{});
    try nav_t.appendChild(cx.allocator, try ui.text(cx, "⚙ 设置", .{
        .font_size = 13,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    try nav.appendChild(cx.allocator, nav_t);

    const items = [_]struct { icon: []const u8, label: []const u8 }{
        .{ .icon = "🎨", .label = "外观与主题" },
        .{ .icon = "⌨️", .label = "快捷键" },
        .{ .icon = "🔗", .label = "SSH 与网络" },
        .{ .icon = "📁", .label = "文件传输" },
        .{ .icon = "✨", .label = "AI 辅助" },
        .{ .icon = "🧩", .label = "协议插件" },
        .{ .icon = "🔔", .label = "通知" },
        .{ .icon = "💾", .label = "数据与日志" },
    };
    for (items, 0..) |it, i| {
        try nav.appendChild(cx.allocator, try navItem(cx, it.icon, it.label, i == 4));
    }
    return nav;
}

fn navItem(cx: *ui.Cx, icon: []const u8, label: []const u8, on: bool) !*ui.Node {
    const ni = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 8 },
        .background = if (on) tok.alpha(tok.acc, 18) else ui.Color.TRANSPARENT, // .07
        .border = if (on) .{ .width = 1, .color = tok.acc, .radius = 0, .side_widths = .{ -1, 2, -1, -1 } } else null,
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 20 },
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 14, .color = if (on) tok.acc else tok.fg2 }));
    try ni.appendChild(cx.allocator, ic);
    try ni.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.acc else tok.fg2,
        .line_height = 1.2,
    }));
    return ni;
}

// ── 内容区（AI 辅助） ───────────────────────────────────────────────

fn mountContent(cx: *ui.Cx) !*ui.Node {
    const ct = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .padding = .{ .left = 26, .right = 26, .top = 18, .bottom = 0 },
        .overflow = .hidden,
        .overflow_hidden = true,
        .flex_shrink = 0,
    }, .{});

    const t = try ui.box(cx, .{
        .width = .fill(),
        .flex_shrink = 0,
    }, .{});
    try t.appendChild(cx.allocator, try ui.text(cx, "AI 辅助", .{
        .font_size = 16,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, t);
    const d = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 3, .bottom = 10 },
        .flex_shrink = 0,
    }, .{});
    try d.appendChild(cx.allocator, try ui.text(cx, "多 Provider 管理 · 所有上下文与命令仅作用于远程服务器，不接触本机 · 上下文用量按所选模型窗口计量", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, d);

    // ── Provider（手风琴卡） ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "Provider（点击卡片就地展开配置 · 长列表互不影响）"));
    try ct.appendChild(cx.allocator, try providerExpanded(cx));
    try ct.appendChild(cx.allocator, try providerCollapsed(cx, ui.Color.rgb(0x10, 0xB9, 0x81), "OpenAI 兼容", "your-gateway/v1 · 1 个模型 · 128k 窗口", "可用"));
    try ct.appendChild(cx.allocator, try providerCollapsed(cx, ui.Color.rgb(0x94, 0xA3, 0xB8), "Ollama（本地）", "localhost:11434 · 全离线隐私 · 32k 窗口", "未配置"));
    try ct.appendChild(cx.allocator, try addProvider(cx));

    // ── 行为 ──
    try ct.appendChild(cx.allocator, try secLabel(cx, "行为"));
    try ct.appendChild(cx.allocator, try settingRow(cx, "默认权限模式", "仅两模式：确认后执行 / 自动执行（白名单）；只读命令两模式均自动；黑名单永远仅可复制", try chip(cx, "✋ 确认后执行")));
    try ct.appendChild(cx.allocator, try settingRow(cx, "上下文脱敏", "发送前掩码 IP / 主机名 / 用户名", try mock.toggle(cx, false)));
    try ct.appendChild(cx.allocator, try settingRowLast(cx, "错误轻提示", "命令非零退出时提示「✨ 问问 AI」；终端采集行数随模型窗口自动缩放", try mock.toggle(cx, true)));

    // ── 底栏 ──
    try ct.appendChild(cx.allocator, try footer(cx));
    return ct;
}

// ── Provider 卡 ─────────────────────────────────────────────────────

/// 展开卡（.pv.on）：头部 + kv 行 + 模型表 + 新增模型。
fn providerExpanded(cx: *ui.Cx) !*ui.Node {
    const pv = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 6 },
        .padding = .{ .left = 13, .right = 13, .top = 9, .bottom = 9 },
        .background = tok.alpha(tok.acc, 5), // rgba(19,69,246,.02)
        .border = .{ .width = 1, .color = tok.acc, .radius = 10 },
        .shadow = .{ .blur = 0, .offset_y = 0, .spread = 3, .color = tok.alpha(tok.acc, 23) }, // rgba(19,69,246,.09)
        .flex_shrink = 0,
    }, .{});
    try pv.appendChild(cx.allocator, try pvHeader(cx, ui.Color.rgb(0x8B, 0x5C, 0xF6), "Anthropic", "api.anthropic.com · 2 个模型", "默认", true));

    // .pv-detail
    const det = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .left = 0, .right = 0, .top = 9, .bottom = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 9, .bottom = 0 },
        .border = .{ .width = 1, .color = pv_detail_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // kv ×3
    try det.appendChild(cx.allocator, try kvRow(cx, "Endpoint", "https://api.anthropic.com", true));
    try det.appendChild(cx.allocator, try kvRow(cx, "API Key", "sk-ant-••••••••••••", true));
    try det.appendChild(cx.allocator, try kvWarn(cx, "存储方式", "明文本地存储 (权限 600) · Keychain 为后续项"));

    // 模型表（margin-top 7）
    const mt = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .left = 0, .right = 0, .top = 7, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    // 表头（.mth）：9.5·600 fg3，padding 5 0，底分隔
    const mth = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .border = .{ .width = 1, .color = mth_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try mth.appendChild(cx.allocator, try gridCell(cx, 140, try ui.text(cx, "模型", .{ .font_size = 9.5, .font_weight = 600, .color = tok.fg3, .line_height = 1.2 })));
    try mth.appendChild(cx.allocator, try gridCellFill(cx, try ui.text(cx, "effort 等级（点击启停）", .{ .font_size = 9.5, .font_weight = 600, .color = tok.fg3, .line_height = 1.2 })));
    try mth.appendChild(cx.allocator, try gridCell(cx, 46, try ui.text(cx, "推理", .{ .font_size = 9.5, .font_weight = 600, .color = tok.fg3, .line_height = 1.2 })));
    try mth.appendChild(cx.allocator, try gridCell(cx, 56, try ui.text(cx, "上下文窗口", .{ .font_size = 9.5, .font_weight = 600, .color = tok.fg3, .line_height = 1.2 })));
    try mth.appendChild(cx.allocator, try gridCell(cx, 34, try ui.text(cx, " ", .{ .font_size = 9.5, .font_weight = 600, .color = tok.fg3, .line_height = 1.2 })));
    try mt.appendChild(cx.allocator, mth);

    // 行 1：claude-sonnet-4（推理支持 acc，默认徽标）
    try mt.appendChild(cx.allocator, try modelRow(cx, "claude-sonnet-4", true, "200k", true));
    // 行 2：claude-haiku-4（推理 —）
    try mt.appendChild(cx.allocator, try modelRow(cx, "claude-haiku-4", false, "200k", false));

    // ＋ 新增模型
    try mt.appendChild(cx.allocator, try addModel(cx));
    try det.appendChild(cx.allocator, mt);

    try pv.appendChild(cx.allocator, det);
    return pv;
}

/// 折叠卡（.pv）：单行头部 + ▸。
fn providerCollapsed(cx: *ui.Cx, dot_color: ui.Color, name: []const u8, meta: []const u8, status: []const u8) !*ui.Node {
    const pv = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 6 },
        .padding = .{ .left = 13, .right = 13, .top = 9, .bottom = 9 },
        .background = tok.white,
        .border = .{ .width = 1, .color = pv_bd, .radius = 10 },
        .flex_shrink = 0,
    }, .{});
    try pv.appendChild(cx.allocator, try pvHeader(cx, dot_color, name, meta, status, false));
    return pv;
}

/// .pv-h：pdot 10² + 名称/地址两行 + 徽标(margin auto) + caret。
fn pvHeader(cx: *ui.Cx, dot_color: ui.Color, name: []const u8, meta: []const u8, status: []const u8, expanded: bool) !*ui.Node {
    const h = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 11,
        .flex_shrink = 0,
    }, .{});
    // .pdot
    try h.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
        .background = dot_color,
        .border = .{ .width = 0, .color = dot_color, .radius = 5 },
        .flex_shrink = 0,
    }, .{}));
    // 名称块
    const nb = try ui.box(cx, .{
        .direction = .column,
        .min_width = 0,
    }, .{});
    try nb.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12.5,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    const pd = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 1, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try pd.appendChild(cx.allocator, try ui.text(cx, meta, .{
        .font_size = 10,
        .color = tok.fg3,
        .use_monospace_font = true,
        .line_height = 1.2,
    }));
    try nb.appendChild(cx.allocator, pd);
    try h.appendChild(cx.allocator, nb);

    // .st 徽标（margin-left:auto）
    const is_default = std.mem.eql(u8, status, "默认");
    const st = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = if (is_default) tok.alpha(tok.grn, 26) else gray_st_bg,
        .border = .{ .width = 0, .color = tok.grn, .radius = 5 },
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try st.appendChild(cx.allocator, try ui.text(cx, status, .{
        .font_size = 9,
        .font_weight = 600,
        .color = if (is_default) grn_txt else tok.fg3,
        .line_height = 1.2,
    }));
    const st_wrap = try ui.box(cx, .{ .flex = 1, .width = .fill(), .direction = .row, .justify = .end, .min_width = 0 }, .{});
    try st_wrap.appendChild(cx.allocator, st);
    try h.appendChild(cx.allocator, st_wrap);

    // .caret
    try h.appendChild(cx.allocator, try ui.text(cx, if (expanded) "▾ 已展开" else "▸ 展开", .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.2,
    }));
    return h;
}

/// .kv 行：k 88px 11.5 fg2 + v mono 11 fg + ed 9.5 acc。
fn kvRow(cx: *ui.Cx, k: []const u8, v: []const u8, edit: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 0, .right = 0, .top = 4, .bottom = 4 },
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 88 },
        .flex_shrink = 0,
    }, .{
        try ui.text(cx, k, .{ .font_size = 11.5, .color = tok.fg2, .line_height = 1.2 }),
    }));
    const vw = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .row,
        .min_width = 0,
    }, .{});
    try vw.appendChild(cx.allocator, try ui.text(cx, v, .{
        .font_size = 11,
        .color = tok.fg,
        .use_monospace_font = true,
        .line_height = 1.2,
    }));
    try row.appendChild(cx.allocator, vw);
    if (edit) {
        try row.appendChild(cx.allocator, try ui.text(cx, "编辑", .{
            .font_size = 9.5,
            .color = tok.acc,
            .line_height = 1.2,
        }));
    }
    return row;
}

/// 存储方式 kv（v 为 Inter 10.5 yel，无编辑）。
fn kvWarn(cx: *ui.Cx, k: []const u8, v: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 0, .right = 0, .top = 4, .bottom = 4 },
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try ui.box(cx, .{
        .width = .{ .px = 88 },
        .flex_shrink = 0,
    }, .{
        try ui.text(cx, k, .{ .font_size = 11.5, .color = tok.fg2, .line_height = 1.2 }),
    }));
    const vw = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .row,
        .min_width = 0,
    }, .{});
    try vw.appendChild(cx.allocator, try ui.text(cx, v, .{
        .font_size = 10.5,
        .color = tok.yel,
        .line_height = 1.2,
    }));
    try row.appendChild(cx.allocator, vw);
    return row;
}

// ── 模型表行（grid 140/1fr/46/56/34 模拟） ──────────────────────────

fn gridCell(cx: *ui.Cx, w: f32, child: *ui.Node) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = w },
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{child});
}

fn gridCellFill(cx: *ui.Cx, child: *ui.Node) !*ui.Node {
    return ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .min_width = 0,
    }, .{child});
}

/// .mtr：模型名(mono 11·600) + effort chips + 推理 + 窗口 + 默认徽标。
fn modelRow(cx: *ui.Cx, model: []const u8, reasoning: bool, window: []const u8, def: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .border = .{ .width = 1, .color = mtr_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 模型名
    try row.appendChild(cx.allocator, try gridCell(cx, 140, try ui.text(cx, model, .{
        .font_size = 11,
        .font_weight = 600,
        .color = tok.fg,
        .use_monospace_font = true,
        .line_height = 1.2,
    })));
    // effort chips：low/medium/high on + xhigh/max off
    const chips = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .min_width = 0,
    }, .{});
    try chips.appendChild(cx.allocator, try ech(cx, "low", true));
    try chips.appendChild(cx.allocator, try ech(cx, "medium", true));
    try chips.appendChild(cx.allocator, try ech(cx, "high", true));
    try chips.appendChild(cx.allocator, try ech(cx, "xhigh", false));
    try chips.appendChild(cx.allocator, try ech(cx, "max", false));
    try row.appendChild(cx.allocator, chips);
    // 推理
    if (reasoning) {
        try row.appendChild(cx.allocator, try gridCell(cx, 46, try ui.text(cx, "🧠 支持", .{
            .font_size = 9,
            .color = tok.acc,
            .line_height = 1.2,
        })));
    } else {
        try row.appendChild(cx.allocator, try gridCell(cx, 46, try ui.text(cx, "—", .{
            .font_size = 9,
            .color = tok.fg3,
            .line_height = 1.2,
        })));
    }
    // 上下文窗口
    try row.appendChild(cx.allocator, try gridCell(cx, 56, try ui.text(cx, window, .{
        .font_size = 9.5,
        .color = tok.fg2,
        .use_monospace_font = true,
        .line_height = 1.2,
    })));
    // 默认徽标
    if (def) {
        const b = try ui.box(cx, .{
            .width = .{ .px = 34 },
            .direction = .row,
            .align_items = .center,
            .flex_shrink = 0,
        }, .{});
        const db = try ui.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
            .background = tok.alpha(tok.grn, 26), // .1
            .border = .{ .width = 0, .color = tok.grn, .radius = 4 },
            .flex_shrink = 0,
        }, .{});
        try db.appendChild(cx.allocator, try ui.text(cx, "默认", .{
            .font_size = 8.5,
            .font_weight = 600,
            .color = grn_txt,
            .line_height = 1.2,
        }));
        try b.appendChild(cx.allocator, db);
        try row.appendChild(cx.allocator, b);
    } else {
        try row.appendChild(cx.allocator, try ui.box(cx, .{
            .width = .{ .px = 34 },
            .flex_shrink = 0,
        }, .{}));
    }
    return row;
}

/// .echip：9px padding 2 7 radius 4。
fn ech(cx: *ui.Cx, label: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 7, .right = 7, .top = 2, .bottom = 2 },
        .background = if (on) tok.alpha(tok.acc, 20) else ui.Color.TRANSPARENT, // .08
        .border = .{ .width = 1, .color = if (on) tok.acc else tok.setbd, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 9,
        .font_weight = if (on) 600 else 400,
        .color = if (on) tok.acc else tok.fg3,
        .line_height = 1.2,
    }));
    return node;
}

/// .addb（新增模型）：margin-top 6 padding 5，dashed 居中。
fn addModel(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .margin = .{ .left = 0, .right = 0, .top = 6, .bottom = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .border = .{ .width = 1, .color = addb_bd, .radius = 10 },
        .flex_shrink = 0,
    }, .{
        try ui.text(cx, "＋ 新增模型", .{ .font_size = 11, .color = tok.acc, .line_height = 1.2 }),
    });
}

/// .addb（新增 Provider）：全宽块，padding 6，底 rgba(255,255,255,.6)。
fn addProvider(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 0, .right = 0, .top = 6, .bottom = 6 },
        .background = tok.alpha(tok.white, 153), // rgba(255,255,255,.6)
        .border = .{ .width = 1, .color = addb_bd, .radius = 10 },
        .flex_shrink = 0,
    }, .{
        try ui.text(cx, "＋ 新增 Provider", .{ .font_size = 11, .color = tok.acc, .line_height = 1.2 }),
    });
}

// ── 局部部件 ────────────────────────────────────────────────────────

fn secLabel(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 10, .bottom = 6 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10,
        .font_weight = 600,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    return node;
}

/// .row（行为区）：padding 6 0，底分隔。
fn settingRow(cx: *ui.Cx, row_title: []const u8, desc: []const u8, control: *ui.Node) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .{ .left = 0, .right = 0, .top = 6, .bottom = 7 },
        .border = .{ .width = 1, .color = row_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const rn = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .column,
        .min_width = 0,
    }, .{});
    try rn.appendChild(cx.allocator, try ui.text(cx, row_title, .{
        .font_size = 12.5,
        .font_weight = 500,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    const dl = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 1, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try dl.appendChild(cx.allocator, try ui.text(cx, desc, .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.4,
    }));
    try rn.appendChild(cx.allocator, dl);
    try row.appendChild(cx.allocator, rn);
    try row.appendChild(cx.allocator, control);
    return row;
}

/// 最后一行（HTML border:none）。
fn settingRowLast(cx: *ui.Cx, row_title: []const u8, desc: []const u8, control: *ui.Node) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .{ .left = 0, .right = 0, .top = 6, .bottom = 7 },
        .flex_shrink = 0,
    }, .{});
    const rn = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .column,
        .min_width = 0,
    }, .{});
    try rn.appendChild(cx.allocator, try ui.text(cx, row_title, .{
        .font_size = 12.5,
        .font_weight = 500,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    const dl = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 1, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try dl.appendChild(cx.allocator, try ui.text(cx, desc, .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.4,
    }));
    try rn.appendChild(cx.allocator, dl);
    try row.appendChild(cx.allocator, rn);
    try row.appendChild(cx.allocator, control);
    return row;
}

/// .chip（本页所有 chip 带 ::after " ▾"）：padding 5 12 radius 7 底 #F4FBF7。
fn chip(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
        .background = chip_bg,
        .border = .{ .width = 1, .color = tok.setbd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11.5,
        .color = tok.fg,
        .line_height = 1.2,
    }));
    try node.appendChild(cx.allocator, try ui.text(cx, " ▾", .{
        .font_size = 11.5,
        .color = tok.fg3,
        .line_height = 1.2,
    }));
    return node;
}

/// .ftr 底栏：右对齐 [恢复默认][保存设置]。
fn footer(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 10, .bottom = 0 },
        .border = .{ .width = 1, .color = ftr_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .margin = .{ .left = 0, .right = 0, .top = 8, .bottom = 0 },
        .flex_shrink = 0,
    }, .{
        try btnSecondary(cx, "恢复默认"),
        try btnPrimary(cx, "保存设置"),
    });
}

fn btnPrimary(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 8 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .font_weight = 600,
        .color = tok.white,
        .line_height = 1.5,
    }));
    return node;
}

fn btnSecondary(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
        .background = ui.Color.rgb(0xF1, 0xF5, 0xF9),
        .border = .{ .width = 1, .color = tok.setbd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .color = tok.fg2,
        .line_height = 1.5,
    }));
    return node;
}
