//! mockup-protocols — 设计稿静态复刻（docs/SPEC/html/mockup-protocols.html）。
//!
//! 新建连接向导步骤 1：720 宽模态（协议 6 卡 + 从已有主机复制虚线条 + 两列表单 +
//! SOCKS5/启动命令卡）。窗口 = .bk 背板 1280×720；模态自然高 ~1090，居中后上下
//! 溢出窗口（与参考 png 一致：模态溢出 720 高背板）。验证时用 png 的 .bk 区域
//! 裁剪（css y 170..890）对照。
//!
//! 注意：CSS 虚线边框（复制条）Zenit 无 dashed 描边，用本地 dashedFrame 逐段模拟。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 720 };
pub const title = "mockup-protocols";

const tok = mock.tok;

// HTML 局部色（:root 只给了一部分，其余按内联样式）
const c_modal = ui.Color.rgb(0xF7, 0xFF, 0xFB); // .md 背景 #F7FFFB
const c_f1f5f9 = ui.Color.rgb(0xF1, 0xF5, 0xF9); // 分隔线/kbd 底
const c_e2e8f0 = ui.Color.rgb(0xE2, 0xE8, 0xF0); // --bd（本页）
const c_fg3 = ui.Color.rgb(0x94, 0xA3, 0xB8); // 灰注
const c_fg2 = ui.Color.rgb(0x47, 0x55, 0x69); // --fg2
const c_black = ui.Color.rgb(0x00, 0x00, 0x00); // 未设 color 的继承黑
const c_f4fbf7 = ui.Color.rgb(0xF4, 0xFB, 0xF7); // .pk / .fi 输入底
const c_f8fafc = ui.Color.rgb(0xF8, 0xFA, 0xFC); // .sup 卡底
const c_slate = ui.Color.rgb(0x64, 0x74, 0x8B); // #64748B
const c_cbd5e1 = ui.Color.rgb(0xCB, 0xD5, 0xE1); // 删除 ×
const c_g059669 = ui.Color.rgb(0x05, 0x96, 0x69); // st-ok 字色
const c_b45309 = ui.Color.rgb(0xB4, 0x53, 0x09); // st-beta 字色

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    // 窗口底 = body #666；.bk 背板 rgba(0,0,0,.25) 铺满窗口（720 高 = 背板高）。
    const bk = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(0, 0, 0, 64),
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try bk.appendChild(cx.allocator, try mountModal(cx));
    return bk;
}

// ── 模态卡片（720 宽，自然高度 ~1090） ─────────────────────────────

fn mountModal(cx: *ui.Cx) !*ui.Node {
    const md = try ui.box(cx, .{
        .width = .{ .px = 720 },
        .direction = .column,
        .background = c_modal,
        .border = .{ .width = 0, .color = c_modal, .radius = 14 },
        .shadow = .{ .blur = 70, .offset_y = 30, .color = ui.Color.rgba(0, 0, 0, 64) },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try md.appendChild(cx.allocator, try mountHeader(cx));
    try md.appendChild(cx.allocator, try mountCopyBar(cx));
    try md.appendChild(cx.allocator, try mountStepRow(cx));
    try md.appendChild(cx.allocator, try mountPicker(cx));
    try md.appendChild(cx.allocator, try mountScopeNote(cx));
    try md.appendChild(cx.allocator, try mountFormArea(cx));
    try md.appendChild(cx.allocator, try mountFooter(cx));
    return md;
}

/// 头部 .mh：18/26/14 padding，标题 16·600，✕ 28²。
fn mountHeader(cx: *ui.Cx) !*ui.Node {
    const h = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 26, .right = 26, .top = 18, .bottom = 14 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const tcol = try ui.box(cx, .{ .flex = 1, .min_width = 0, .direction = .row }, .{});
    try tcol.appendChild(cx.allocator, try ui.text(cx, "＋ 新建连接 · 步骤 1/3 基本信息", .{
        .font_size = 16,
        .font_weight = 600,
        .color = c_black,
    }));
    try h.appendChild(cx.allocator, tcol);
    const x = try ui.box(cx, .{
        .width = .{ .px = 28 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .background = c_f1f5f9,
        .border = .{ .width = 0, .color = c_f1f5f9, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try x.appendChild(cx.allocator, try ui.text(cx, "✕", .{ .font_size = 13, .color = c_fg3 }));
    try h.appendChild(cx.allocator, x);
    return h;
}

/// 复制条（margin 12/26/0 + dashed 边 + 8/12 padding）。
fn mountCopyBar(cx: *ui.Cx) !*ui.Node {
    const outer = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 26, .right = 26, .top = 12, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    // 内容行：h 29（8+8 padding + 内容 13）
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 29 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.acc, 10), // rgba(19,69,246,.04)
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try ui.text(cx, "⧉", .{ .font_size = 13, .color = c_black }));
    try row.appendChild(cx.allocator, try ui.text(cx, "从已有主机复制:", .{
        .font_size = 11.5,
        .font_weight = 600,
        .color = tok.fg,
    }));
    // 选择框：flex 1，白底 #E2E8F0 边 圆角7，字 11 fg2
    const sel = try ui.box(cx, .{
        .height = .{ .px = 21 },
        .flex = 1,
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 7 },
    }, .{});
    try sel.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01（地址/用户/跳板链/启动命令一并带入）▾", .{
        .font_size = 11,
        .color = c_fg2,
    }));
    try row.appendChild(cx.allocator, sel);
    try row.appendChild(cx.allocator, try ui.text(cx, "名称自动加 -副本", .{
        .font_size = 9.5,
        .color = c_fg3,
    }));
    try outer.appendChild(cx.allocator, try dashedFrame(cx, row, tok.alpha(tok.acc, 56), 9));
    return outer;
}

/// 虚线描边容器：Zenit 无 dashed border，用四边逐段小盒近似（dash 4 / gap 3）。
fn dashedFrame(cx: *ui.Cx, content: *ui.Node, color: ui.Color, radius: f32) !*ui.Node {
    _ = radius;
    const frame = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try frame.appendChild(cx.allocator, try dashEdgeH(cx, color));
    const mid = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .flex_shrink = 0,
    }, .{});
    try mid.appendChild(cx.allocator, try dashEdgeV(cx, color));
    try mid.appendChild(cx.allocator, content);
    try mid.appendChild(cx.allocator, try dashEdgeV(cx, color));
    try frame.appendChild(cx.allocator, mid);
    try frame.appendChild(cx.allocator, try dashEdgeH(cx, color));
    return frame;
}

fn dashEdgeH(cx: *ui.Cx, color: ui.Color) !*ui.Node {
    const edge = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 1 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{});
    // 4px dash + 3px gap ×120 段足够覆盖 672 宽。
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        try edge.appendChild(cx.allocator, try ui.box(cx, .{
            .width = .{ .px = 4 },
            .height = .{ .px = 1 },
            .background = color,
            .margin = .{ .top = 0, .right = 3, .bottom = 0, .left = 0 },
            .flex_shrink = 0,
        }, .{}));
    }
    return edge;
}

fn dashEdgeV(cx: *ui.Cx, color: ui.Color) !*ui.Node {
    const edge = try ui.box(cx, .{
        .width = .{ .px = 1 },
        .direction = .column,
        .flex_shrink = 0,
    }, .{});
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try edge.appendChild(cx.allocator, try ui.box(cx, .{
            .width = .{ .px = 1 },
            .height = .{ .px = 4 },
            .background = color,
            .margin = .{ .top = 0, .right = 0, .bottom = 3, .left = 0 },
            .flex_shrink = 0,
        }, .{}));
    }
    return edge;
}

/// 步骤行：margin 10/26/0。
fn mountStepRow(cx: *ui.Cx) !*ui.Node {
    const outer = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 26, .right = 26, .top = 10, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try outer.appendChild(cx.allocator, try ui.text(cx, "1 基本信息", .{
        .font_size = 12,
        .font_weight = 700,
        .color = tok.acc,
    }));
    try outer.appendChild(cx.allocator, try ui.text(cx, "→", .{ .font_size = 12, .color = c_fg3 }));
    try outer.appendChild(cx.allocator, try ui.text(cx, "2 跳板（可跳过）", .{ .font_size = 12, .color = c_black }));
    try outer.appendChild(cx.allocator, try ui.text(cx, "→", .{ .font_size = 12, .color = c_fg3 }));
    try outer.appendChild(cx.allocator, try ui.text(cx, "3 确认", .{ .font_size = 12, .color = c_black }));
    try outer.appendChild(cx.allocator, try ui.spacer(cx));
    try outer.appendChild(cx.allocator, try ui.text(cx, "直连时第 2 步只显示「不使用跳板」，下一步仍到确认", .{
        .font_size = 12,
        .color = c_slate,
    }));
    return outer;
}

/// 协议选择区 .pk：6 列卡片（高 123，gap 9），底 #F4FBF7。
fn mountPicker(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .gap = 9,
        .padding = .{ .left = 26, .right = 26, .top = 16, .bottom = 16 },
        .background = c_f4fbf7,
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{
        try protoCard(cx, "🖥️", "SSH", "首发", .ok, true, false),
        try protoCard(cx, "📂", "SFTP", "首发", .ok, false, false),
        try protoCard(cx, "🗂️", "FTP/S", "P6 自研", .beta, false, true),
        try protoCard(cx, "🖥", "VNC", "后续", .beta, false, true),
        try protoCard(cx, "🪟", "RDP", "P8 FreeRDP", .plan, false, true),
        try protoCard(cx, "🔌", "KVM", "后续", .plan, false, true),
    });
}

fn protoCard(cx: *ui.Cx, icon: []const u8, name: []const u8, status: []const u8, st: enum { ok, beta, plan }, on: bool, dis: bool) !*ui.Node {
    const card = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .height = .{ .px = 123 },
        .direction = .column,
        .align_items = .center,
        .padding = .{ .left = 6, .right = 6, .top = 12, .bottom = 11 },
        .background = tok.white,
        .border = .{ .width = 2, .color = if (on) tok.acc else c_e2e8f0, .radius = 11 },
        .shadow = if (on) .{ .blur = 0, .offset_y = 0, .offset_x = 0, .color = tok.alpha(tok.acc, 26) } else null,
        .opacity = if (dis) 0.55 else 1.0,
        .flex_shrink = 0,
    }, .{});
    const icon_box = try ui.box(cx, .{
        .margin = .{ .top = 0, .right = 0, .bottom = 5, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try icon_box.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 15,
        .color = c_black,
    }));
    try card.appendChild(cx.allocator, icon_box);
    try card.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 11.5,
        .font_weight = 600,
        .color = tok.fg,
    }));
    // 状态徽标 .pi-st：字 8.5，padding 1/6，圆角 3
    const st_colors: [3]ui.Color = .{ c_g059669, c_b45309, c_fg3 };
    const pill = try ui.box(cx, .{
        .height = .{ .px = 11 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
        .background = switch (st) {
            .ok => tok.alpha(tok.grn, 26),
            .beta => tok.alpha(tok.yel, 31),
            .plan => c_f1f5f9,
        },
        .border = .{ .width = 0, .color = tok.white, .radius = 3 },
        .margin = .{ .top = 3, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try pill.appendChild(cx.allocator, try ui.text(cx, status, .{
        .font_size = 8.5,
        .color = st_colors[@intFromEnum(st)],
    }));
    try card.appendChild(cx.allocator, pill);
    return card;
}

/// 版本范围提示条：margin 0/26，padding 7/12，高 25。
fn mountScopeNote(cx: *ui.Cx) !*ui.Node {
    const outer = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 26, .right = 26, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    const note = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 25 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.grn, 13), // rgba(16,185,129,.05)
        .border = .{ .width = 1, .color = tok.alpha(tok.grn, 46), .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    const line = try ui.box(cx, .{ .direction = .row }, .{});
    try line.appendChild(cx.allocator, try ui.text(cx, "当前版本范围：", .{ .font_size = 10.5, .color = c_fg2 }));
    try line.appendChild(cx.allocator, try ui.text(cx, "SSH / SFTP", .{ .font_size = 10.5, .font_weight = 700, .color = tok.fg }));
    try line.appendChild(cx.allocator, try ui.text(cx, "（+ AI 辅助）· 其余协议按标准插件契约后续接入，不在本次交付", .{ .font_size = 10.5, .color = c_fg2 }));
    try note.appendChild(cx.allocator, line);
    try outer.appendChild(cx.allocator, note);
    return outer;
}

// ── 表单区 .mb（20/26） ───────────────────────────────────────────

fn mountFormArea(cx: *ui.Cx) !*ui.Node {
    const mb = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 26, .right = 26, .top = 20, .bottom = 20 },
        .flex_shrink = 0,
    }, .{});

    // 两列表单 .fg（gap 12，margin-bottom 14）
    const fg = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .gap = 12,
        .margin = .{ .top = 0, .right = 0, .bottom = 14, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    // 左列：主机别名 / 目标地址 / 跳板
    const col_l = try ui.box(cx, .{ .flex = 1, .min_width = 0, .direction = .column, .gap = 12 }, .{});
    try col_l.appendChild(cx.allocator, try fieldInput(cx, "主机别名", "K8s-Node03", false));
    try col_l.appendChild(cx.allocator, try fieldInput(cx, "目标地址", "10.200.1.20", true));
    try col_l.appendChild(cx.allocator, try fieldInput(cx, "跳板（可选）", "不使用 · 直连目标", true));
    // 右列：分组 / (端口|用户名)
    const col_r = try ui.box(cx, .{ .flex = 1, .min_width = 0, .direction = .column, .gap = 12 }, .{});
    try col_r.appendChild(cx.allocator, try fieldInput(cx, "分组", "生产环境 / Kubernetes", false));
    const duo = try ui.box(cx, .{ .direction = .row, .gap = 10 }, .{});
    const duo_l = try ui.box(cx, .{ .flex = 1, .min_width = 0 }, .{});
    try duo_l.appendChild(cx.allocator, try fieldInput(cx, "端口", "22", true));
    const duo_r = try ui.box(cx, .{ .flex = 1, .min_width = 0 }, .{});
    try duo_r.appendChild(cx.allocator, try fieldInput(cx, "用户名", "ubuntu", true));
    try duo.appendChild(cx.allocator, duo_l);
    try duo.appendChild(cx.allocator, duo_r);
    try col_r.appendChild(cx.allocator, duo);
    try fg.appendChild(cx.allocator, col_l);
    try fg.appendChild(cx.allocator, col_r);
    try mb.appendChild(cx.allocator, fg);

    // 端口转发小节
    try mb.appendChild(cx.allocator, try sectionTitle(cx, "🔀 端口转发（SOCKS5 动态转发 · 完整可配置）"));
    try mb.appendChild(cx.allocator, try mountSocksCard(cx));

    // 启动命令小节
    try mb.appendChild(cx.allocator, try sectionTitle(cx, "🚀 启动命令（连接成功后自动执行 · 需求 #7）"));
    try mb.appendChild(cx.allocator, try mountCmdsCard(cx));
    return mb;
}

/// 表单字段：label 11.5·500 fg2（高 17）+ 输入 35（8/12 padding，字 13/mono12）。
fn fieldInput(cx: *ui.Cx, label: []const u8, value: []const u8, mono: bool) !*ui.Node {
    const fg2 = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 5,
        .flex_shrink = 0,
    }, .{});
    try fg2.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11.5,
        .font_weight = 500,
        .color = c_fg2,
    }));
    const fi = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 35 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = c_f4fbf7,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try fi.appendChild(cx.allocator, try ui.text(cx, value, .{
        .font_size = if (mono) 12 else 13,
        .color = tok.fg,
        .use_monospace_font = mono,
    }));
    try fg2.appendChild(cx.allocator, fi);
    return fg2;
}

/// 小节标题 .sec-t：12.5·600，margin 14/0/10，下边线，高 25。
fn sectionTitle(cx: *ui.Cx, text: []const u8) !*ui.Node {
    const t = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 25 },
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .margin = .{ .top = 14, .right = 0, .bottom = 10, .left = 0 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try t.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 12.5,
        .font_weight = 600,
        .color = c_black,
    }));
    return t;
}

/// SOCKS5 转发卡 .sup：11/13 padding，底 #F8FAFC 边 #E2E8F0 圆角9。
fn mountSocksCard(cx: *ui.Cx) !*ui.Node {
    const sup = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 13, .right = 13, .top = 11, .bottom = 11 },
        .background = c_f8fafc,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 9 },
        .margin = .{ .top = 0, .right = 0, .bottom = 14, .left = 0 },
        .flex_shrink = 0,
    }, .{});

    // 头行：标题 + 开关（32×18 on）
    const head = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 19 },
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 0, .right = 0, .bottom = 8, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "启用 SOCKS5 转发", .{
        .font_size = 11.5,
        .font_weight = 500,
        .color = c_black,
    }));
    try head.appendChild(cx.allocator, try ui.spacer(cx));
    try head.appendChild(cx.allocator, try miniToggle(cx, 32, 18, true));
    try sup.appendChild(cx.allocator, head);

    // 行区：padding 4/12/10
    const body = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 10 },
        .flex_shrink = 0,
    }, .{});
    try body.appendChild(cx.allocator, try cfgRow(cx, "本地端口", "1080", "冲突自动 +1", c_fg3));
    try body.appendChild(cx.allocator, try cfgRow(cx, "绑定地址", "127.0.0.1", "改 0.0.0.0 暴露局域网 ⚠", tok.yel));
    try body.appendChild(cx.allocator, try cfgRow(cx, "出口节点", "链路末端 ▾", "多跳时任一已认证跳可选", c_fg3));
    // 自动开启行：label + off 开关 + 注
    const r4 = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 27 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try r4.appendChild(cx.allocator, try fixedText(cx, "连接时自动开启", .{
        .font_size = 11.5,
        .color = tok.fg,
    }, 84));
    try r4.appendChild(cx.allocator, try miniToggle(cx, 30, 17, false));
    try r4.appendChild(cx.allocator, try ui.text(cx, "含自动重连恢复", .{ .font_size = 9.5, .color = c_fg3 }));
    try body.appendChild(cx.allocator, r4);

    try body.appendChild(cx.allocator, try boxedText(cx, "仅 TCP CONNECT · 会话内可 @socks 随时开关 · 侧栏可「仅开转发不开终端」", .{
        .font_size = 9.5,
        .color = c_fg3,
    }, .{ .top = 4, .right = 0, .bottom = 0, .left = 0 }));
    try sup.appendChild(cx.allocator, body);
    return sup;
}

/// 配置行：label 84 + 输入（150 宽 mono 11）+ 右注。
fn cfgRow(cx: *ui.Cx, label: []const u8, value: []const u8, note: []const u8, note_color: ui.Color) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 27 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try fixedText(cx, label, .{
        .font_size = 11.5,
        .color = tok.fg,
    }, 84));
    const val = try ui.box(cx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 26 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    const mono = !std.mem.eql(u8, label, "出口节点");
    try val.appendChild(cx.allocator, try ui.text(cx, value, .{
        .font_size = 11,
        .color = tok.fg,
        .use_monospace_font = mono,
    }));
    try row.appendChild(cx.allocator, val);
    const warn = std.mem.eql(u8, label, "绑定地址");
    try row.appendChild(cx.allocator, try ui.text(cx, note, .{
        .font_size = 9.5,
        .font_weight = if (warn) 600 else 400,
        .color = note_color,
    }));
    return row;
}

/// 小开关：w×h（32×18 on 蓝点白 14；30×17 off 灰点白 13）。
fn miniToggle(cx: *ui.Cx, w: f32, h: f32, on: bool) !*ui.Node {
    const knob: f32 = if (on) 14 else 13;
    return ui.box(cx, .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .direction = .row,
        .align_items = .center,
        .justify = if (on) .end else .start,
        .padding = .{ .left = 2, .right = 2, .top = 0, .bottom = 0 },
        .background = if (on) tok.acc else c_cbd5e1,
        .border = .{ .width = 0, .color = tok.acc, .radius = h / 2 },
        .flex_shrink = 0,
    }, .{
        try ui.box(cx, .{
            .width = .{ .px = knob },
            .height = .{ .px = knob },
            .background = tok.white,
            .border = .{ .width = 0, .color = tok.white, .radius = knob / 2 },
        }, .{}),
    });
}

/// 启动命令卡 .sup。
fn mountCmdsCard(cx: *ui.Cx) !*ui.Node {
    const sup = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 13, .right = 13, .top = 11, .bottom = 11 },
        .background = c_f8fafc,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 9 },
        .flex_shrink = 0,
    }, .{});
    const head = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 19 },
        .direction = .row,
        .align_items = .center,
        .margin = .{ .top = 0, .right = 0, .bottom = 8, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "启用启动命令序列", .{
        .font_size = 11.5,
        .font_weight = 500,
        .color = c_black,
    }));
    try head.appendChild(cx.allocator, try ui.spacer(cx));
    try head.appendChild(cx.allocator, try miniToggle(cx, 32, 18, true));
    try sup.appendChild(cx.allocator, head);

    const cmds = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 5,
        .flex_shrink = 0,
    }, .{});
    try cmds.appendChild(cx.allocator, try cmdRow(cx, "1", "cd /opt/deploy"));
    try cmds.appendChild(cx.allocator, try cmdRow(cx, "2", "source ~/.envrc"));
    try cmds.appendChild(cx.allocator, try cmdRow(cx, "3", "ll"));
    try sup.appendChild(cx.allocator, cmds);

    try sup.appendChild(cx.allocator, try boxedText(cx, "＋ 添加命令 · 支持 expect-send 对（交互确认场景）", .{
        .font_size = 11,
        .color = tok.acc,
    }, .{ .top = 3, .right = 0, .bottom = 0, .left = 0 }));
    try sup.appendChild(cx.allocator, try boxedText(cx, "Shell 就绪（首个提示符或 500ms 静默）后按序注入；注入内容回显但不计入命令历史", .{
        .font_size = 10,
        .color = c_fg3,
    }, .{ .top = 8, .right = 0, .bottom = 0, .left = 0 }));
    return sup;
}

fn cmdRow(cx: *ui.Cx, num: []const u8, cmd: []const u8) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 26 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .flex_shrink = 0,
    }, .{});
    try row.appendChild(cx.allocator, try fixedText(cx, num, .{
        .font_size = 10,
        .color = c_fg3,
    }, 14));
    const c = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .height = .{ .px = 26 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 9, .right = 9, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 6 },
    }, .{});
    try c.appendChild(cx.allocator, try ui.text(cx, cmd, .{
        .font_size = 11.5,
        .color = tok.fg,
        .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, c);
    try row.appendChild(cx.allocator, try ui.text(cx, "✕", .{
        .font_size = 11,
        .color = c_cbd5e1,
    }));
    return row;
}

/// 底栏 .mf：14/26/18，右对齐 取消/下一步。
fn mountFooter(cx: *ui.Cx) !*ui.Node {
    const mf = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 66 },
        .direction = .row,
        .align_items = .center,
        .justify = .end,
        .gap = 10,
        .padding = .{ .left = 26, .right = 26, .top = 14, .bottom = 18 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 次按钮 .b2：9/18 padding，13 号，底 #F1F5F9 边 #E2E8F0
    const b2 = try ui.box(cx, .{
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .background = c_f1f5f9,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try b2.appendChild(cx.allocator, try ui.text(cx, "取消", .{ .font_size = 13, .color = c_fg2 }));
    try mf.appendChild(cx.allocator, b2);
    // 主按钮 .b1：9/22，渐变+阴影
    const b1 = try ui.box(cx, .{
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 22, .right = 22, .top = 0, .bottom = 0 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = tok.alpha(tok.acc, 64) },
        .flex_shrink = 0,
    }, .{});
    try b1.appendChild(cx.allocator, try ui.text(cx, "下一步", .{
        .font_size = 13,
        .font_weight = 600,
        .color = tok.white,
    }));
    try mf.appendChild(cx.allocator, b1);
    return mf;
}

/// 定宽文本盒：ui.text 无 width/margin 属性，用外层盒承担。
fn fixedText(cx: *ui.Cx, content: []const u8, props: ui.TextStyle, w: f32) !*ui.Node {
    const b = try ui.box(cx, .{
        .width = .{ .px = w },
        .flex_shrink = 0,
    }, .{});
    try b.appendChild(cx.allocator, try ui.text(cx, content, props));
    return b;
}

/// 带外边距的文本盒。
fn boxedText(cx: *ui.Cx, content: []const u8, props: ui.TextStyle, m: ui.Padding) !*ui.Node {
    const b = try ui.box(cx, .{
        .margin = m,
        .flex_shrink = 0,
    }, .{});
    try b.appendChild(cx.allocator, try ui.text(cx, content, props));
    return b;
}
