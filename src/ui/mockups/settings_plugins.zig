//! mockup-settings-plugins — 设置 · 协议插件页（docs/SPEC/html/mockup-settings-plugins.html）。
//!
//! 结构：背板 1280×760 + 居中模态 840×600（Nav 190 + 内容区 + 底栏）。
//! 插件行 = 30² 图标卡 + 名称/描述 + 状态徽标（已启用·首发 绿 / 后续版本 黄）+ 开关。
//! 所有尺寸/颜色逐条对照 HTML CSS。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 760 };
pub const title = "mockup-settings-plugins";

const tok = mock.tok;

// ── 设置系局部 token ────────────────────────────────────────────────

const backdrop = ui.Color.rgb(0x4C, 0x4C, 0x4C);
const modal_bg = ui.Color.rgb(0xF7, 0xFF, 0xFB);
const nav_bg = tok.setnav;
const nav_bd = ui.Color.rgb(0xE4, 0xF1, 0xE8);
const nav_t_sep = ui.Color.rgb(0xE4, 0xF1, 0xE8); // 本页 .nav-t border-bottom
const row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // .row border-bottom
const pic_bg = ui.Color.rgb(0xF4, 0xF8, 0xF6); // .pic 背景
const b2_bg = ui.Color.rgb(0xF1, 0xF5, 0xF9);
const ftr_sep = ui.Color.rgb(0xE9, 0xF3, 0xEC); // .ftr border-top
const grn_txt = ui.Color.rgb(0x05, 0x96, 0x69); // .st.ok 字色
const yel_txt = ui.Color.rgb(0xB4, 0x53, 0x09); // .st.later 字色

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
        .width = .{ .px = 840 },
        .height = .{ .px = 600 },
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

// ── Nav（190px，on=协议插件；.on 底 acc.07） ─────────────────────────

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
        try nav.appendChild(cx.allocator, try navItem(cx, it.icon, it.label, i == 5));
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
        .background = if (on) tok.alpha(tok.acc, 18) else ui.Color.TRANSPARENT, // rgba(19,69,246,.07)
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

// ── 内容区（协议插件） ──────────────────────────────────────────────

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
    try t.appendChild(cx.allocator, try ui.text(cx, "协议插件", .{
        .font_size = 16,
        .font_weight = 700,
        .color = tok.fg,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, t);
    const d = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 3, .bottom = 12 },
        .flex_shrink = 0,
    }, .{});
    try d.appendChild(cx.allocator, try ui.text(cx, "当前版本范围仅 SSH / SFTP（+AI）；其余为后续方向，按标准插件契约（§7）接入", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.5,
    }));
    try ct.appendChild(cx.allocator, d);

    // 插件行 ×6
    try ct.appendChild(cx.allocator, try pluginRow(cx, "🖥️", "SSH", "libssh2 + mbedtls · 多跳 ProxyJump · PTY", true, true));
    try ct.appendChild(cx.allocator, try pluginRow(cx, "📂", "SFTP", "独立传输连接 · 滑动窗口 · 断点续传", true, true));
    try ct.appendChild(cx.allocator, try pluginRow(cx, "🗂️", "FTP / FTPS", "纯 Zig 自研 RFC 959 · REST 续传（可选）", false, false));
    try ct.appendChild(cx.allocator, try pluginRow(cx, "🖥", "VNC", "自研 RFB 3.8 · Zenit 位图渲染 · 键鼠映射", false, false));
    try ct.appendChild(cx.allocator, try pluginRow(cx, "🪟", "RDP", "FreeRDP (Apache-2.0) C FFI 帧缓冲集成", false, false));
    try ct.appendChild(cx.allocator, try pluginRow(cx, "🔌", "KVM (Redfish)", "BMC 电源/传感器/虚拟介质 · iKVM 后评估", false, false));

    // 契约说明条（.note）
    const note = try ui.box(cx, .{
        .width = .fill(),
        .margin = .{ .left = 0, .right = 0, .top = 12, .bottom = 0 },
        .padding = .{ .left = 12, .right = 12, .top = 9, .bottom = 9 },
        .background = tok.alpha(tok.acc, 8), // rgba(19,69,246,.03)
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 20), .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try note.appendChild(cx.allocator, try ui.text(cx, "插件契约（manifest / Session / RenderNode / TransferEngine / 统一错误码）v1 已冻结：后续协议实现契约 + 注册表登记即可接入，不改主程序结构；传输类自动复用统一传输面板与「文件传输」页参数。", .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.6,
    }));
    try ct.appendChild(cx.allocator, note);

    // ── 底栏 ──
    try ct.appendChild(cx.allocator, try footer(cx));
    return ct;
}

/// 插件行：30² 图标 + 名称(12.5·600)/描述(10 fg3) + 状态徽标 + 开关。
fn pluginRow(cx: *ui.Cx, icon: []const u8, name: []const u8, desc: []const u8, ok: bool, on: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .padding = .{ .left = 0, .right = 0, .top = 9, .bottom = 10 },
        .border = .{ .width = 1, .color = row_sep, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // .pic 30² 圆角 8
    const pic = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 30 },
        .align_items = .center,
        .justify = .center,
        .background = pic_bg,
        .border = .{ .width = 0, .color = pic_bg, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try pic.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 15, .color = tok.fg2 }));
    try row.appendChild(cx.allocator, pic);

    const rn = try ui.box(cx, .{
        .flex = 1,
        .width = .fill(),
        .direction = .column,
        .min_width = 0,
    }, .{});
    try rn.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12.5,
        .font_weight = 600,
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

    // .st 徽标：9px 600 padding 2 8 radius 5
    try row.appendChild(cx.allocator, try statusBadge(cx, if (ok) "已启用 · 首发" else "后续版本", ok));
    // 开关
    try row.appendChild(cx.allocator, try mock.toggle(cx, on));
    return row;
}

/// 状态徽标：ok=绿系 / later=黄系。
fn statusBadge(cx: *ui.Cx, label: []const u8, ok: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = if (ok) tok.alpha(tok.grn, 26) else tok.alpha(tok.yel, 26), // .1
        .border = .{ .width = 0, .color = tok.grn, .radius = 5 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 9,
        .font_weight = 600,
        .color = if (ok) grn_txt else yel_txt,
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
        .padding = .{ .left = 0, .right = 0, .top = 12, .bottom = 0 },
        .border = .{ .width = 1, .color = ftr_sep, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .margin = .{ .left = 0, .right = 0, .top = 12, .bottom = 0 },
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
        .background = b2_bg,
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
