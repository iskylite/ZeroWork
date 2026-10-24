//! mockup-linkchain — 设计稿静态复刻（docs/SPEC/html/mockup-linkchain.html）。
//!
//! 主窗口（tbar 40 + term 600 + sbar 28 = 668 高）：终端 4 行（含光标）+
//! 右下通信链路弹层 .lcp（700 宽，锚 ProxyJump 胶囊正上方，三角 12²
//! rotate45 → 以叠置白方块近似）+ 状态栏（绿点/链路/RTT/UTF-8/尺寸/
//! ⬡ ProxyJump ×2 ▾ 胶囊）。拓扑链节点 4 卡 + 渐变箭头 + RTT 标签。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 668 };
pub const title = "mockup-linkchain";

const tok = mock.tok;

// HTML 局部色
const c_acc2 = ui.Color.rgb(0x3B, 0x82, 0xF6); // .tb #3B82F6
const c_g059669 = ui.Color.rgb(0x05, 0x96, 0x69); // .lbtn.p 字色
const c_f8fafc = ui.Color.rgb(0xF8, 0xFA, 0xFC); // .lbtn 底
const c_r0 = ui.Color.rgba(0, 0, 0, 13); // .lcp-f 上边线 rgba(0,0,0,.05)

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountTerm(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40：红绿灯 + DB-Master 页签 + 右侧全局图标） ─────

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
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "DB-Master ✕", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    // 右侧全局图标（⚡ ⇅ ✨(acc) ⚙️）
    for ([_][]const u8{ "⚡", "⇅", "✨", "⚙️" }) |icon| {
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
        try bar.appendChild(cx.allocator, icn);
    }
    return bar;
}

// ── 终端区（term 600：4 行 + 链路弹层） ───────────────────────────

fn mountTerm(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 600 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    const dim = tok.alpha(tok.fg, 140);
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "dbadmin", .color = tok.cyn },
        .{ .text = "@db-master:", .color = tok.fg },
        .{ .text = "~", .color = c_acc2 },
        .{ .text = "$ sudo systemctl status postgresql", .color = tok.fg },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "● postgresql.service - PostgreSQL 16 database server", .color = dim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "   Active: ", .color = dim },
        .{ .text = "active (exited)", .color = tok.grn },
        .{ .text = " since Tue 2026-09-15", .color = dim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "dbadmin", .color = tok.cyn },
        .{ .text = "@db-master:", .color = tok.fg },
        .{ .text = "~", .color = c_acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = false, .cursor = true }));

    // 链路弹层 .lcp：absolute 右 24 / 底 34 / 700 宽
    const lcp = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .right = .{ .px = 24 }, .bottom = .{ .px = 34 } },
        .width = .{ .px = 700 },
        .direction = .column,
        .background = ui.Color.rgba(248, 255, 251, 242), // .95
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 18) },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) },
        .z_index = 50,
        .padding = .{ .left = 18, .right = 18, .top = 14, .bottom = 14 },
        .flex_shrink = 0,
    }, .{});

    // 头行：⬡ 通信链路: DB-Master + 右侧端到端
    const head = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 0, .right = 0, .bottom = 12, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try head.appendChild(cx.allocator, try ui.text(cx, "⬡ 通信链路: DB-Master", .{
        .font_size = 12.5,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.3,
    }));
    try head.appendChild(cx.allocator, try ui.spacer(cx));
    try head.appendChild(cx.allocator, try ui.text(cx, "● 端到端 46ms · 全链路正常", .{
        .font_size = 10.5,
        .font_weight = 600,
        .color = tok.grn,
        .line_height = 1.3,
    }));
    try lcp.appendChild(cx.allocator, head);

    // 拓扑链：4 节点 + 3 渐变箭头（.arr 44 宽）
    const chain = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .stretch,
        .margin = .{ .top = 0, .right = 0, .bottom = 6, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try chain.appendChild(cx.allocator, try nodeCard(cx, .mac, "💻 本机", "ZeroWork · macOS 26", "起点"));
    try chain.appendChild(cx.allocator, try arrow(cx, "TCP 24ms"));
    try chain.appendChild(cx.allocator, try nodeCard(cx, .jump, "🛡️ Bastion-01", "ops_jumper@118.31.22.10:2222", "ed25519 · aes256-gcm · curve25519"));
    try chain.appendChild(cx.allocator, try arrow(cx, "隧道 +18ms"));
    try chain.appendChild(cx.allocator, try nodeCard(cx, .jump, "🔀 VPC-Transit", "tunnel_svc@10.100.0.5:22", "ed25519 · aes256-gcm · direct-tcpip"));
    try chain.appendChild(cx.allocator, try arrow(cx, "隧道 +4ms"));
    try chain.appendChild(cx.allocator, try nodeCard(cx, .dst, "🗄️ DB-Master", "dbadmin@10.200.4.18:22", "ed25519 + OTP ✓ · chacha20 · 120×36"));
    try lcp.appendChild(cx.allocator, chain);

    // 说明行：两条左注 + 右注（9.5 fg3）
    const note = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 14,
        .padding = .{ .left = 2, .right = 2, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    try note.appendChild(cx.allocator, try ui.text(cx, "悬浮节点查看详情/重连此跳", .{ .font_size = 9.5, .color = tok.fg3, .line_height = 1.3 }));
    try note.appendChild(cx.allocator, try ui.text(cx, "断线时故障跳红色高亮并点名", .{ .font_size = 9.5, .color = tok.fg3, .line_height = 1.3 }));
    try note.appendChild(cx.allocator, try ui.spacer(cx));
    try note.appendChild(cx.allocator, try ui.text(cx, "▾ 弹层三角精确指向 ProxyJump 胶囊中心（触发点即锚点）", .{ .font_size = 9.5, .color = tok.fg3, .line_height = 1.3 }));
    try lcp.appendChild(cx.allocator, note);

    // 底部按钮行 .lcp-f：上边线 + 4 按钮（编辑配置 margin-left auto）
    const foot = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .margin = .{ .top = 12, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .left = 0, .right = 0, .top = 10, .bottom = 0 },
        .border = .{ .width = 1, .color = c_r0, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try foot.appendChild(cx.allocator, try lbtn(cx, "🔍 测试全链路", true));
    try foot.appendChild(cx.allocator, try lbtn(cx, "⧉ 复制链路报告", false));
    try foot.appendChild(cx.allocator, try lbtn(cx, "⧉ 复制 ssh -J 命令", false));
    try foot.appendChild(cx.allocator, try ui.spacer(cx));
    try foot.appendChild(cx.allocator, try lbtn(cx, "⚙ 编辑配置", false));
    try lcp.appendChild(cx.allocator, foot);

    // 弹层三角（::after 12² rotate45）：Zenit 无旋转 → 以 9px 白色小圆近似（png 中观感即小凸起）
    const tri = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .bottom = .{ .px = -5 }, .right = .{ .px = 58 } },
        .width = .{ .px = 9 },
        .height = .{ .px = 9 },
        .background = ui.Color.rgba(248, 255, 251, 255),
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 18), .radius = 3 },
        .z_index = 51,
        .flex_shrink = 0,
    }, .{});
    try lcp.appendChild(cx.allocator, tri);

    try term.appendChild(cx.allocator, lcp);
    return term;
}

const NodeKind = enum { mac, jump, dst };

/// 拓扑节点卡 .node：flex 1，1.5px 描边圆角 10，白底（色按 kind）；
/// nn 11.5·600 + 6px 状态点；nm mono 8.5 fg2；nd 9 fg3。
fn nodeCard(cx: *ui.Cx, kind: NodeKind, head: []const u8, addr: []const u8, detail: []const u8) !*ui.Node {
    const bd_color: ui.Color = switch (kind) {
        .mac => tok.grn,
        .jump => tok.acc,
        .dst => tok.acc,
    };
    const bg: ui.Color = switch (kind) {
        .mac => tok.alpha(tok.grn, 8),
        .jump => tok.alpha(tok.acc, 8),
        .dst => tok.alpha(tok.acc, 13),
    };
    const card = try ui.box(cx, .{
        .flex = 1,
        .min_width = 0,
        .direction = .column,
        .padding = .{ .left = 11, .right = 11, .top = 9, .bottom = 9 },
        .background = bg,
        .border = .{ .width = 1.5, .color = bd_color, .radius = 10 },
        .flex_shrink = 0,
    }, .{});
    // 标题行：6px 状态点 + 标题
    const nn = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    try nn.appendChild(cx.allocator, try mock.dot(cx, 6, tok.grn));
    try nn.appendChild(cx.allocator, try ui.text(cx, head, .{
        .font_size = 11.5,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.3,
    }));
    try card.appendChild(cx.allocator, nn);
    try card.appendChild(cx.allocator, try ui.text(cx, addr, .{
        .font_size = 8.5,
        .color = tok.fg2,
        .use_monospace_font = true,
        .line_height = 1.4,
        .text_overflow = .clip,
    }));
    try card.appendChild(cx.allocator, try ui.text(cx, detail, .{
        .font_size = 9,
        .color = tok.fg3,
        .line_height = 1.4,
        .text_overflow = .clip,
    }));
    return card;
}

/// 渐变箭头 .arr：44 宽 / 2px 高 32 长渐变线 + ▸ / 8px 标签。
fn arrow(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const arr = try ui.box(cx, .{
        .width = .{ .px = 44 },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .flex_shrink = 0,
    }, .{});
    // 线 + 箭头字（▸ 定位在右端 → 行内拼接近似）
    const line = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    const bar = try ui.box(cx, .{
        .width = .{ .px = 26 },
        .height = .{ .px = 2 },
        .gradient = .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .horizontal },
        .flex_shrink = 0,
    }, .{});
    try line.appendChild(cx.allocator, bar);
    try line.appendChild(cx.allocator, try ui.text(cx, "▸", .{
        .font_size = 11,
        .color = ui.Color.rgb(0x25, 0x63, 0xEB),
        .line_height = 1.0,
    }));
    try arr.appendChild(cx.allocator, line);
    try arr.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 8,
        .color = tok.fg3,
        .use_monospace_font = true,
        .line_height = 1.5,
    }));
    return arr;
}

/// 底部按钮 .lbtn：5/12 padding 圆角 7 字 10.5·500；p = 绿系。
fn lbtn(cx: *ui.Cx, label: []const u8, primary: bool) !*ui.Node {
    const b = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
        .background = if (primary) tok.alpha(tok.grn, 20) else c_f8fafc,
        .border = .{
            .width = 1,
            .color = if (primary) tok.alpha(tok.grn, 64) else tok.bd,
            .radius = 7,
        },
        .flex_shrink = 0,
    }, .{});
    try b.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10.5,
        .font_weight = 500,
        .color = if (primary) c_g059669 else tok.fg2,
        .line_height = 1.2,
    }));
    return b;
}

// ── 状态栏（sbar 28：链路信息 + ProxyJump 胶囊） ──────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "Bastion-01 → db-master", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "RTT 46ms", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "UTF-8", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "120×36", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    // ProxyJump 胶囊 .pj：acc.10 底 + 600 + 外圈 1.5 acc.35
    const pj = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 10, .right = 10, .top = 2, .bottom = 2 },
        .background = tok.alpha(tok.acc, 26),
        .border = .{ .width = 1.5, .color = tok.alpha(tok.acc, 89), .radius = 10 },
        .flex_shrink = 0,
    }, .{});
    try pj.appendChild(cx.allocator, try ui.text(cx, "⬡ ProxyJump ×2 ▾", .{
        .font_size = 11,
        .font_weight = 600,
        .color = tok.acc,
        .line_height = 1.2,
    }));
    try bar.appendChild(cx.allocator, pj);
    return bar;
}
