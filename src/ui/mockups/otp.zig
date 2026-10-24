//! mockup-otp — 设计稿静态复刻（docs/SPEC/html/mockup-otp.html）。
//!
//! 主窗口（tbar 40 + term 540 + sbar 28 = 608 高）+ 会话浮层
//! rgba(236,255,244,.5)+blur6，居中 430 宽 OTP 卡：标题 / sub /
//! 步骤列表（✓绿 / 2蓝） / 6 格验证码（40×48 圆角9 mono20） /
//! 倒计时环行 / TOTP 自动填充开关行 / 取消连接 + 验证并继续↵。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 608 };
pub const title = "mockup-otp";

const tok = mock.tok;

// HTML 局部色
const c_e2e8f0 = ui.Color.rgb(0xE2, 0xE8, 0xF0); // 环底 / 未聚焦格边
const c_2563eb = ui.Color.rgb(0x25, 0x63, 0xEB); // 渐变末端

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40：红绿灯 + 🔒 DB-Master 激活页签） ─────────────

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
    try tab.appendChild(cx.allocator, try ui.text(cx, "🔒", .{ .font_size = 11, .color = tok.fg }));
    try tab.appendChild(cx.allocator, try ui.text(cx, "DB-Master (连接中…) ✕", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 终端区（term 540：四行日志 + 浮层 + OTP 卡） ──────────────────

fn mountBody(cx: *ui.Cx) !*ui.Node {
    const term = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 540 },
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    const dim = tok.alpha(tok.fg, 140);
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 正在建立链路: Bastion-01 → VPC-Transit → DB-Master …", .color = dim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 第 1 跳 Bastion-01 ✓ 已认证 (ed25519)", .color = dim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 第 2 跳 VPC-Transit ✓ 已认证 (ed25519)", .color = dim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 终点 DB-Master: 密钥通过，服务端要求二次验证 (keyboard-interactive)", .color = dim },
    }, .{}));

    const ov = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = tok.alpha(tok.bg, 128),
        .glass = .{ .backdrop_blur = 6 },
        .z_index = 10,
        .flex_shrink = 0,
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    try term.appendChild(cx.allocator, ov);
    return term;
}

/// OTP 卡 .otpc：430 宽 / 白 .95 / 圆角 12 / 22/26 padding。
fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 430 },
        .direction = .column,
        .background = ui.Color.rgba(255, 255, 255, 242),
        .border = .{ .width = 1, .color = ui.Color.rgba(15, 23, 42, 18) },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) },
        .padding = .{ .left = 26, .right = 26, .top = 22, .bottom = 22 },
        .flex_shrink = 0,
    }, .{});

    try card.appendChild(cx.allocator, try ui.text(cx, "🔐 双重验证 — DB-Master", .{
        .font_size = 14,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.3,
    }));
    const sub = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .top = 5, .right = 0, .bottom = 14, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try sub.appendChild(cx.allocator, try ui.text(cx, "终点主机 dbadmin@10.200.4.18 要求输入动态验证码（第 3 跳 ·", .{
        .font_size = 11,
        .color = tok.fg2,
        .line_height = 1.5,
    }));
    try sub.appendChild(cx.allocator, try ui.text(cx, "keyboard-interactive）", .{
        .font_size = 11,
        .color = tok.fg2,
        .line_height = 1.5,
    }));
    try card.appendChild(cx.allocator, sub);

    // 步骤列表 .step：15² 圆徽 + 11 字，行距 3px
    try card.appendChild(cx.allocator, try stepRow(cx, "✓", "私钥认证 ed25519_prod — 已通过", .done));
    try card.appendChild(cx.allocator, try stepRow(cx, "2", "动态验证码（TOTP）— 等待输入", .cur));

    // 验证码 6 格 .digits：gap 9 居中 margin 16/0/10
    const digits = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .gap = 9,
        .margin = .{ .top = 16, .right = 0, .bottom = 10, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try digits.appendChild(cx.allocator, try digitBox(cx, "8", .focus));
    try digits.appendChild(cx.allocator, try digitBox(cx, "4", .focus));
    try digits.appendChild(cx.allocator, try digitBox(cx, "2", .focus));
    try digits.appendChild(cx.allocator, try digitBox(cx, "9", .focus));
    try digits.appendChild(cx.allocator, try digitBox(cx, "1", .cursor));
    try digits.appendChild(cx.allocator, try digitBox(cx, "", .empty));
    try card.appendChild(cx.allocator, digits);

    // 倒计时行 .orow：环 15 + 文本
    const orow = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .gap = 7,
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try orow.appendChild(cx.allocator, try countdownRing(cx));
    try orow.appendChild(cx.allocator, try ui.text(cx, "本码剩余 23s · 输满 6 位自动提交", .{
        .font_size = 10.5,
        .color = tok.fg2,
        .line_height = 1.3,
    }));
    try card.appendChild(cx.allocator, orow);

    // 自动填充行 .autof：开关 26×15 on + 文本
    const autof = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .gap = 7,
        .flex_shrink = 0,
    }, .{});
    try autof.appendChild(cx.allocator, try swToggle(cx));
    try autof.appendChild(cx.allocator, try ui.text(cx, "TOTP 自动填充已启用（密钥已本地保存，仅需确认）", .{
        .font_size = 10.5,
        .color = tok.fg2,
        .line_height = 1.3,
    }));
    try card.appendChild(cx.allocator, autof);

    // 操作行
    const oacts = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .gap = 10,
        .margin = .{ .top = 16, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try oacts.appendChild(cx.allocator, try obButton(cx, "取消连接", false));
    try oacts.appendChild(cx.allocator, try obButton(cx, "验证并继续 ↵", true));
    try card.appendChild(cx.allocator, oacts);
    return card;
}

const StepKind = enum { done, cur };

/// 步骤行：15² 圆徽（done=grn ✓ / cur=acc 数字）+ 11 字（cur 500 fg）。
fn stepRow(cx: *ui.Cx, badge: []const u8, label: []const u8, kind: StepKind) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 21 }, // 15 徽 + 3 上下
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .align_items = .center,
        .justify = .center,
        .background = if (kind == .done) tok.grn else tok.acc,
        .border = .{ .width = 0, .color = tok.white, .radius = 7.5 },
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, badge, .{
        .font_size = 9,
        .font_weight = 600,
        .color = tok.white,
        .line_height = 1.0,
    }));
    try row.appendChild(cx.allocator, ic);
    try row.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 11,
        .font_weight = if (kind == .cur) 500 else 400,
        .color = if (kind == .cur) tok.fg else tok.fg2,
        .line_height = 1.4,
    }));
    return row;
}

const DigitKind = enum { focus, cursor, empty };

/// 验证码格 .dg：40×48 圆角 9 mono 20·600；focus=acc 边+3px ring；cursor=acc 边；empty=bd 边。
fn digitBox(cx: *ui.Cx, ch: []const u8, kind: DigitKind) !*ui.Node {
    const dg = try ui.box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 48 },
        .align_items = .center,
        .justify = .center,
        .background = tok.white,
        .border = .{
            .width = 1.5,
            .color = if (kind == .empty) c_e2e8f0 else tok.acc,
            .radius = 9,
        },
        .shadow = if (kind == .focus) .{ .color = tok.alpha(tok.acc, 31), .blur = 0, .offset_x = 0, .offset_y = 0, .spread = 3 } else null,
        .flex_shrink = 0,
    }, .{});
    if (ch.len > 0) {
        try dg.appendChild(cx.allocator, try ui.text(cx, ch, .{
            .font_size = 20,
            .font_weight = 600,
            .color = tok.fg,
            .use_monospace_font = true,
            .line_height = 1.0,
        }));
    }
    return dg;
}

/// 倒计时环 .ring：15² conic 75% acc + 内白圆（inset 3 → 9² 白）。
fn countdownRing(cx: *ui.Cx) !*ui.Node {
    const ring = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .align_items = .center,
        .justify = .center,
        .gradient = .{ .from = tok.acc, .to = tok.acc, .direction = .conic },
        .border = .{ .width = 0, .color = tok.white, .radius = 7.5 },
        .flex_shrink = 0,
    }, .{});
    try ring.appendChild(cx.allocator, try mock.dot(cx, 9, tok.white));
    return ring;
}

/// 迷你开关 .sw2：26×15 圆角 8 on（白点 12 右侧）。
fn swToggle(cx: *ui.Cx) !*ui.Node {
    const track = try ui.box(cx, .{
        .width = .{ .px = 26 },
        .height = .{ .px = 15 },
        .direction = .row,
        .align_items = .center,
        .justify = .end,
        .padding = .{ .left = 2, .right = 2, .top = 0, .bottom = 0 },
        .background = tok.acc,
        .border = .{ .width = 0, .color = tok.acc, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try track.appendChild(cx.allocator, try mock.dot(cx, 12, tok.white));
    return track;
}

/// 操作按钮 .ob（与 auth-pwd 同规格）。
fn obButton(cx: *ui.Cx, label: []const u8, primary: bool) !*ui.Node {
    const b = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 8 },
        .background = if (primary) ui.Color.TRANSPARENT else ui.Color.rgba(0, 0, 0, 8),
        .gradient = if (primary) .{ .from = tok.acc, .to = c_2563eb, .direction = .diagonal } else null,
        .border = .{ .width = if (primary) 0 else 1, .color = if (primary) tok.acc else tok.bd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try b.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .font_weight = if (primary) 600 else 400,
        .color = if (primary) tok.white else tok.fg2,
        .line_height = 1.2,
    }));
    return b;
}

// ── 状态栏（sbar 28：黄点 + 链路状态） ────────────────────────────

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
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.yel));
    try bar.appendChild(cx.allocator, try ui.text(cx, "连接中: 2/3 跳已就绪 · 等待 DB-Master 二次验证", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
