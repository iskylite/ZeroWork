//! mockup-proxyjump — 设计稿静态复刻（docs/SPEC/html/mockup-proxyjump.html）。
//!
//! 新建连接向导步骤 2/3 跳板链：780 宽白色模态居中于 1280×720 暗背板
//! （body #666 → .modal-backdrop rgba(0,0,0,.25)+blur8 铺满窗口）。
//! 顶部步骤条说明浮层（fixed）复刻在模态头部右上。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 720 };
pub const title = "mockup-proxyjump";

const tok = mock.tok;

// HTML 局部色（:root 未覆盖的内联样式）
const c_black = ui.Color.rgb(0x00, 0x00, 0x00); // 未设 color 的继承黑
const c_fg = ui.Color.rgb(0x0F, 0x17, 0x2A); // --fg-primary
const c_fg2 = ui.Color.rgb(0x47, 0x55, 0x69); // --fg-secondary
const c_fg3 = ui.Color.rgb(0x94, 0xA3, 0xB8); // #94A3B8
const c_slate = ui.Color.rgb(0x64, 0x74, 0x8B); // 浮层说明字
const c_f1f5f9 = ui.Color.rgb(0xF1, 0xF5, 0xF9); // 分隔线/次按钮底/close 底
const c_e2e8f0 = ui.Color.rgb(0xE2, 0xE8, 0xF0); // 输入边
const c_fafbfc = ui.Color.rgb(0xFA, 0xFB, 0xFC); // 输入底
const c_cbd5e1 = ui.Color.rgb(0xCB, 0xD5, 0xE1); // 未选 radio 描边 / 箭头
const c_g059669 = ui.Color.rgb(0x05, 0x96, 0x69); // 测试通过字色
const c_2563eb = ui.Color.rgb(0x25, 0x63, 0xEB); // 渐变末端

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    // body #666 → .modal-backdrop rgba(0,0,0,.25)+blur8 铺满窗口
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.rgba(0, 0, 0, 64),
        .glass = .{ .backdrop_blur = 8 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try root.appendChild(cx.allocator, try mountModal(cx));
    try root.appendChild(cx.allocator, try mountStepTip(cx));
    return root;
}

// ── 模态（780 宽） ────────────────────────────────────────────────

fn mountModal(cx: *ui.Cx) !*ui.Node {
    const md = try ui.box(cx, .{
        .width = .{ .px = 780 },
        .direction = .column,
        .background = tok.white,
        .border = .{ .width = 0, .color = tok.white, .radius = 14 },
        .shadow = .{ .blur = 70, .offset_y = 30, .color = ui.Color.rgba(0, 0, 0, 64) },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    try md.appendChild(cx.allocator, try mountHeader(cx));
    try md.appendChild(cx.allocator, try mountBody(cx));
    try md.appendChild(cx.allocator, try mountFooter(cx));
    return md;
}

/// .modal-header：20/28/16 padding，标题 16·600，✕ 28²。
fn mountHeader(cx: *ui.Cx) !*ui.Node {
    const h = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 28, .right = 28, .top = 20, .bottom = 16 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const tcol = try ui.box(cx, .{ .flex = 1, .min_width = 0, .direction = .row }, .{});
    try tcol.appendChild(cx.allocator, try ui.text(cx, "🔗 新建连接 · 步骤 2/3 跳板链", .{
        .font_size = 16,
        .font_weight = 600,
        .color = c_fg,
    }));
    try h.appendChild(cx.allocator, tcol);
    try h.appendChild(cx.allocator, try ui.spacer(cx));
    try h.appendChild(cx.allocator, try closeButton(cx));
    return h;
}

/// 28² 圆角 7 关闭按钮（#F1F5F9 底，✕ 13 fg3）。
fn closeButton(cx: *ui.Cx) !*ui.Node {
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
    return x;
}

/// .modal-body：24/28 padding。表单两列（左右行序按 HTML 视觉网格）。
fn mountBody(cx: *ui.Cx) !*ui.Node {
    const body = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 28, .right = 28, .top = 24, .bottom = 24 },
        .flex_shrink = 0,
    }, .{});

    const grid = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 12,
        .margin = .{ .top = 0, .right = 0, .bottom = 20, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    // 行 1：别名 | 分组；行 2：地址 | 端口+用户名；行 3：认证方式（全宽）；
    // 行 4：私钥路径 | Passphrase。
    const row1 = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 14, .flex_shrink = 0 }, .{});
    try row1.appendChild(cx.allocator, try fieldInput(cx, "主机别名", "DB-Master-Prod", false));
    try row1.appendChild(cx.allocator, try fieldInput(cx, "分组", "生产环境 / Database", false));
    try grid.appendChild(cx.allocator, row1);
    const row2 = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 14, .align_items = .end, .flex_shrink = 0 }, .{});
    const addr_wrap = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .direction = .column, .flex_shrink = 0 }, .{});
    try addr_wrap.appendChild(cx.allocator, try fieldInput(cx, "目标地址", "10.200.4.18", true));
    try row2.appendChild(cx.allocator, addr_wrap);
    const duo = try ui.box(cx, .{ .width = .{ .px = 355 }, .direction = .row, .gap = 10, .flex_shrink = 0 }, .{});
    try duo.appendChild(cx.allocator, try fieldInput(cx, "端口", "22", true));
    try duo.appendChild(cx.allocator, try fieldInput(cx, "用户名", "dbadmin", true));
    try row2.appendChild(cx.allocator, duo);
    try grid.appendChild(cx.allocator, row2);
    try grid.appendChild(cx.allocator, try authRow(cx));
    const row4 = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 14, .flex_shrink = 0 }, .{});
    try row4.appendChild(cx.allocator, try fieldInput(cx, "私钥路径", "~/.ssh/id_ed25519_prod", true));
    try row4.appendChild(cx.allocator, try fieldInput(cx, "Passphrase", "•••••••••••••••", true));
    try grid.appendChild(cx.allocator, row4);
    try body.appendChild(cx.allocator, grid);

    try body.appendChild(cx.allocator, try sectionTitle(cx, "🌐", "网络跳板代理 (ProxyJump Topology)"));
    try body.appendChild(cx.allocator, try mountTopology(cx));

    try body.appendChild(cx.allocator, try sectionTitle(cx, "⚙️", "高级终端参数"));
    const adv = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .gap = 14,
        .flex_shrink = 0,
    }, .{});
    try adv.appendChild(cx.allocator, try fieldInput(cx, "终端类型", "xterm-256color", false));
    try adv.appendChild(cx.allocator, try fieldInput(cx, "默认编码", "UTF-8", false));
    try adv.appendChild(cx.allocator, try fieldInput(cx, "滚动历史", "50000 行", false));
    try body.appendChild(cx.allocator, adv);
    return body;
}

/// 表单字段：label 11.5·500 fg2 + 输入 35（8/12 padding，字 13/mono 12）。
fn fieldInput(cx: *ui.Cx, label: []const u8, value: []const u8, mono: bool) !*ui.Node {
    const fg = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 5,
        .flex_shrink = 0,
    }, .{});
    try fg.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11.5,
        .font_weight = 500,
        .color = c_fg2,
        .line_height = 1.25,
    }));
    const fi = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = c_fafbfc,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try fi.appendChild(cx.allocator, try ui.text(cx, value, .{
        .font_size = if (mono) 12 else 13,
        .color = c_fg,
        .use_monospace_font = mono,
        .line_height = 1.2,
    }));
    try fg.appendChild(cx.allocator, fi);
    return fg;
}

/// 认证方式行：label + 三个 radio（12.5 字，gap 14）。
fn authRow(cx: *ui.Cx) !*ui.Node {
    const wrap = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 5,
        .flex_shrink = 0,
    }, .{});
    try wrap.appendChild(cx.allocator, try ui.text(cx, "认证方式", .{
        .font_size = 11.5,
        .font_weight = 500,
        .color = c_fg2,
    }));
    const grp = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 14,
        .padding = .{ .left = 0, .right = 0, .top = 4, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try grp.appendChild(cx.allocator, try radioItem(cx, "密码登录", false));
    try grp.appendChild(cx.allocator, try radioItem(cx, "SSH 私钥证书", true));
    try grp.appendChild(cx.allocator, try radioItem(cx, "macOS Keychain", false));
    try wrap.appendChild(cx.allocator, grp);
    return wrap;
}

/// radio 项：16² 圆 + 12.5 字（active = accent 实心环心）。
fn radioItem(cx: *ui.Cx, label: []const u8, on: bool) !*ui.Node {
    const item = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    const circle = try ui.box(cx, .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
        .align_items = .center,
        .justify = .center,
        .background = tok.white,
        .border = .{ .width = 2, .color = if (on) tok.acc else c_cbd5e1, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    if (on) {
        // radial-gradient(circle, acc 40%, transparent 41%)：蓝环内白隙 + 6px 蓝点
        try circle.appendChild(cx.allocator, try mock.dot(cx, 6, tok.acc));
    }
    try item.appendChild(cx.allocator, circle);
    try item.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .color = c_fg,
    }));
    return item;
}

/// 小节标题：13·600 + 图标 16，下边线（margin-bottom 14 / padding-bottom 8）。
fn sectionTitle(cx: *ui.Cx, icon: []const u8, text: []const u8) !*ui.Node {
    const t = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 14, .left = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 8 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try t.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 16, .color = c_black }));
    try t.appendChild(cx.allocator, try ui.text(cx, text, .{
        .font_size = 13,
        .font_weight = 600,
        .color = c_fg,
    }));
    return t;
}

// ── 拓扑图（.topology：对角渐变底 + 圆角 12 + 20/24 padding） ─────

fn mountTopology(cx: *ui.Cx) !*ui.Node {
    const topo = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 24, .right = 24, .top = 16, .bottom = 16 },
        .gradient = .{
            .from = ui.Color.rgb(0xF8, 0xFA, 0xFC),
            .to = ui.Color.rgb(0xF0, 0xF9, 0xFF),
            .direction = .diagonal,
        },
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 12 },
        .margin = .{ .top = 0, .right = 0, .bottom = 16, .left = 0 },
        .flex_shrink = 0,
    }, .{});

    // 节点链（scale .92 的影响并入节点宽与间距）
    const chain = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    try chain.appendChild(cx.allocator, try topoNode(cx, .source, "💻", "我的 Mac", "Local Machine", null));
    try chain.appendChild(cx.allocator, try topoArrow(cx, "Direct TCP"));
    try chain.appendChild(cx.allocator, try topoNode(cx, .bastion, "🛡️", "Bastion-Public", "118.31.22.10:2222", "ops_jumper"));
    try chain.appendChild(cx.allocator, try topoArrow(cx, "SSH Tunnel"));
    try chain.appendChild(cx.allocator, try topoNode(cx, .bastion, "🔀", "VPC-Transit", "10.100.0.5:22", "tunnel_svc"));
    try chain.appendChild(cx.allocator, try topoArrow(cx, "Direct-TCPIP"));
    try chain.appendChild(cx.allocator, try topoNode(cx, .target, "🗄️", "DB-Master", "10.200.4.18:22", "dbadmin"));
    try topo.appendChild(cx.allocator, chain);

    // 操作行：＋添加跳板节点 / ↕调整顺序 / 🔍测试全链路连通性（绿）
    const acts = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .gap = 10,
        .margin = .{ .top = 12, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try acts.appendChild(cx.allocator, try topoBtn(cx, "＋ 添加跳板节点", false));
    try acts.appendChild(cx.allocator, try topoBtn(cx, "↕ 调整顺序", false));
    try acts.appendChild(cx.allocator, try topoBtn(cx, "🔍 测试全链路连通性", true));
    try topo.appendChild(cx.allocator, acts);
    return topo;
}

const NodeKind = enum { source, bastion, target };

/// 拓扑节点卡：宽 ~117（scale .92 折算）居中（icon 18 / name 11.5·600 / addr 9.2 mono / user 8.7 acc）。
fn topoNode(cx: *ui.Cx, kind: NodeKind, icon: []const u8, name: []const u8, addr: []const u8, user: ?[]const u8) !*ui.Node {
    const bd_color: ui.Color = switch (kind) {
        .source => tok.acc,
        .bastion => tok.yel,
        .target => tok.grn,
    };
    const bg: ui.Color = switch (kind) {
        .source => tok.alpha(tok.acc, 8), // .03
        .bastion => tok.alpha(tok.yel, 8),
        .target => tok.alpha(tok.grn, 8),
    };
    const node = try ui.box(cx, .{
        .width = .{ .px = 117 },
        .direction = .column,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 7 },
        .background = bg,
        .border = .{ .width = 1.5, .color = bd_color, .radius = 9 },
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, icon, .{ .font_size = 17, .color = c_black, .line_height = 1.25 }));
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 11.5,
        .font_weight = 600,
        .color = c_fg,
        .line_height = 1.3,
    }));
    try node.appendChild(cx.allocator, try ui.text(cx, addr, .{
        .font_size = 9.2,
        .color = c_fg2,
        .use_monospace_font = true,
        .line_height = 1.35,
    }));
    if (user) |u| {
        try node.appendChild(cx.allocator, try ui.text(cx, u, .{ .font_size = 8.7, .color = tok.acc, .line_height = 1.3 }));
    }
    return node;
}

/// 箭头：━…▶ 16px（#CBD5E1）+ 下方标签 8.3px（scale .92 折算）。
fn topoArrow(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const arr = try ui.box(cx, .{
        .direction = .column,
        .align_items = .center,
        .padding = .{ .left = 5, .right = 5, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try arr.appendChild(cx.allocator, try ui.text(cx, "━━▶", .{
        .font_size = 16,
        .color = c_cbd5e1,
        .line_height = 1.3,
    }));
    try arr.appendChild(cx.allocator, try ui.text(cx, label, .{ .font_size = 8.3, .color = c_fg2, .line_height = 1.4 }));
    return arr;
}

/// 拓扑按钮：11 字 5/14 padding 圆角 6；test = 绿系（.08 底 .2 边 #059669 字）。
fn topoBtn(cx: *ui.Cx, label: []const u8, is_test: bool) !*ui.Node {
    const b = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 5, .bottom = 5 },
        .background = if (is_test) tok.alpha(tok.grn, 20) else tok.white,
        .border = .{
            .width = 1,
            .color = if (is_test) tok.alpha(tok.grn, 51) else c_e2e8f0,
            .radius = 6,
        },
        .flex_shrink = 0,
    }, .{});
    try b.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11,
        .color = if (is_test) c_g059669 else c_fg2,
    }));
    return b;
}

// ── 底栏：测试结果（mr auto）+ 取消 + 下一步 ──────────────────────

fn mountFooter(cx: *ui.Cx) !*ui.Node {
    const f = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 66 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 28, .right = 28, .top = 16, .bottom = 20 },
        .border = .{ .width = 1, .color = c_f1f5f9, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 测试结果（margin-right:auto → spacer）
    const res = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    try res.appendChild(cx.allocator, try mock.dot(cx, 8, tok.grn));
    try res.appendChild(cx.allocator, try ui.text(cx, "测试通过 (全链路 RTT: 46ms)", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.grn,
    }));
    try f.appendChild(cx.allocator, res);
    try f.appendChild(cx.allocator, try ui.spacer(cx));
    // 次按钮 9/20
    const b2 = try ui.box(cx, .{
        .height = .{ .px = 35 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 20, .right = 20, .top = 0, .bottom = 0 },
        .background = c_f1f5f9,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try b2.appendChild(cx.allocator, try ui.text(cx, "取消", .{ .font_size = 13, .color = c_fg2 }));
    try f.appendChild(cx.allocator, b2);
    // 主按钮 9/24 渐变 + 投影
    const b1 = try ui.box(cx, .{
        .height = .{ .px = 35 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 24, .right = 24, .top = 0, .bottom = 0 },
        .gradient = .{ .from = tok.acc, .to = c_2563eb, .direction = .diagonal },
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .shadow = .{ .blur = 12, .offset_y = 4, .color = tok.alpha(tok.acc, 64) },
        .flex_shrink = 0,
    }, .{});
    try b1.appendChild(cx.allocator, try ui.text(cx, "下一步", .{
        .font_size = 13,
        .font_weight = 600,
        .color = tok.white,
    }));
    try f.appendChild(cx.allocator, b1);
    return f;
}

// ── 顶部步骤说明浮层（fixed 顶部居中：left 50% 平移 ≈ 640 − 半宽） ──

fn mountStepTip(cx: *ui.Cx) !*ui.Node {
    const tip = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 44 }, .left = .{ .px = 558 } },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
        .background = tok.white,
        .border = .{ .width = 1, .color = c_e2e8f0, .radius = 8 },
        .shadow = .{ .blur = 18, .offset_y = 6, .color = ui.Color.rgba(15, 23, 42, 40) },
        .z_index = 80,
        .flex_shrink = 0,
    }, .{});
    try tip.appendChild(cx.allocator, try ui.text(cx, "1 基本信息 → ", .{ .font_size = 11, .color = c_slate }));
    try tip.appendChild(cx.allocator, try ui.text(cx, "2 跳板", .{ .font_size = 11, .font_weight = 700, .color = tok.acc }));
    try tip.appendChild(cx.allocator, try ui.text(cx, " → 3 确认", .{ .font_size = 11, .color = c_slate }));
    return tip;
}
