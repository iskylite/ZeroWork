//! mockup-connect-confirm — 设计稿静态复刻（docs/SPEC/html/mockup-connect-confirm.html）。
//!
//! 新建连接向导步骤 3/3 确认：主窗口（tbar 40 + body 560 + sbar 28 = 628 高）
//! 上叠 rgba(236,255,244,.5)+blur5 会话浮层，居中 560 宽确认卡。
//! 摘要行 .k 92 宽 + 值；测试行 #059669·600；按钮行 上一步/重新测试/保存并连接。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 628 };
pub const title = "mockup-connect-confirm";

const tok = mock.tok;

// HTML 局部色
const c_f2f9f4 = ui.Color.rgb(0xF2, 0xF9, 0xF4); // .row 分隔线
const c_f4fbf7 = ui.Color.rgb(0xF4, 0xFB, 0xF7); // .b 按钮底
const c_2563eb = ui.Color.rgb(0x25, 0x63, 0xEB); // 渐变末端
const c_g059669 = ui.Color.rgb(0x05, 0x96, 0x69); // 测试成功字色

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40：红绿灯 + 激活页签） ──────────────────────────

fn mountTitleBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 红绿灯组：12px 圆 gap 8（与预览程序原生红绿灯重叠）
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
    // 激活页签：bg=--bg + 阴影 + 12·500
    const tab = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.bg,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .shadow = .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) },
        .flex_shrink = 0,
    }, .{});
    try tab.appendChild(cx.allocator, try ui.text(cx, "K8s-Node01 ✕", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 主体（body 560：压暗浮层 + 确认卡） ───────────────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    const body = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 560 },
        .flex_shrink = 0,
    }, .{});
    // .ov：rgba(236,255,244,.5) + blur5 铺满（absolute 节点显式 fill）
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = tok.alpha(tok.bg, 128), // .5
        .glass = .{ .backdrop_blur = 5 },
        .flex_shrink = 0,
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    try body.appendChild(cx.allocator, ov);
    return body;
}

/// 确认卡：560 宽 / 圆角 12 / rgba(248,255,251,.97) / 边 acc.12 / 18/20 padding。
fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .direction = .column,
        .background = ui.Color.rgba(248, 255, 251, 247), // .97
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 31), .radius = 12 },
        .shadow = .{ .blur = 48, .offset_y = 18, .color = ui.Color.rgba(15, 23, 42, 41) },
        .padding = .{ .left = 20, .right = 20, .top = 18, .bottom = 18 },
        .flex_shrink = 0,
    }, .{});

    // 标题 + 说明
    try card.appendChild(cx.allocator, try ui.text(cx, "新建连接 · 步骤 3/3 确认", .{
        .font_size = 14,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.3,
    }));
    const sub = try ui.box(cx, .{
        .margin = .{ .top = 4, .right = 0, .bottom = 12, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try sub.appendChild(cx.allocator, try ui.text(cx, "与步骤 1、步骤 2 同一模态。点测试连接后才允许保存。", .{
        .font_size = 11,
        .color = tok.fg3,
        .line_height = 1.4,
    }));
    try card.appendChild(cx.allocator, sub);

    // 摘要行（.row：border-top #F2F9F4，8/0 padding，gap 10）
    try card.appendChild(cx.allocator, try summaryRow(cx, "主机", "DB-Master · dbadmin@10.200.4.20:22", false));
    try card.appendChild(cx.allocator, try summaryRow(cx, "跳板", "Bastion-01 → VPC-Transit → 末端", false));
    try card.appendChild(cx.allocator, try summaryRow(cx, "认证", "公钥 id_ed25519 · OTP 已配置", false));
    try card.appendChild(cx.allocator, try summaryRow(cx, "SOCKS5", "127.0.0.1:1080 · 出口=链路末端 · 连接时自动开", false));
    try card.appendChild(cx.allocator, try summaryRow(cx, "测试", "✓ 三跳握手成功 · RTT 46ms · 主机密钥已记录", true));

    // 按钮行（右对齐 gap 10 margin-top 16）
    const btns = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .end,
        .align_items = .center,
        .gap = 10,
        .margin = .{ .top = 16, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try btns.appendChild(cx.allocator, try smallButton(cx, "上一步", false));
    try btns.appendChild(cx.allocator, try smallButton(cx, "重新测试", false));
    try btns.appendChild(cx.allocator, try smallButton(cx, "保存并连接", true));
    try card.appendChild(cx.allocator, btns);
    return card;
}

/// 摘要行：.k 92 fg2 + 值 12（测试行 #059669·600）。
fn summaryRow(cx: *ui.Cx, key: []const u8, value: []const u8, ok: bool) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 35 }, // 8+8 padding + 12 字 ≈ 35
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .border = .{ .width = 1, .color = c_f2f9f4, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    const k = try ui.box(cx, .{ .width = .{ .px = 92 }, .flex_shrink = 0 }, .{});
    try k.appendChild(cx.allocator, try ui.text(cx, key, .{
        .font_size = 12,
        .color = tok.fg2,
        .line_height = 1.3,
    }));
    try row.appendChild(cx.allocator, k);
    try row.appendChild(cx.allocator, try ui.text(cx, value, .{
        .font_size = 12,
        .font_weight = if (ok) 600 else 400,
        .color = if (ok) c_g059669 else tok.fg,
        .line_height = 1.3,
    }));
    return row;
}

/// 小按钮 .b/.bp：高 34，圆角 8；bp 渐变白字 12.5·650。
fn smallButton(cx: *ui.Cx, label: []const u8, primary: bool) !*ui.Node {
    const b = try ui.box(cx, .{
        .height = .{ .px = 34 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = if (primary) 18 else 16, .right = if (primary) 18 else 16, .top = 0, .bottom = 0 },
        .background = if (primary) ui.Color.TRANSPARENT else c_f4fbf7,
        .gradient = if (primary) .{ .from = tok.acc, .to = c_2563eb, .direction = .diagonal } else null,
        .border = .{ .width = if (primary) 0 else 1, .color = if (primary) tok.acc else tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try b.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12.5,
        .font_weight = if (primary) 600 else 400,
        .color = if (primary) tok.white else tok.fg2,
        .line_height = 1.2,
    }));
    return b;
}

// ── 状态栏（sbar 28） ─────────────────────────────────────────────

fn mountStatusBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .background = tok.stbg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try ui.text(cx, "向导第三步：摘要 + 测试连接结果。失败时保存按钮禁用，并点名失败跳", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
