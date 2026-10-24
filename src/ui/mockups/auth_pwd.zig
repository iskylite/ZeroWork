//! mockup-auth-pwd — 设计稿静态复刻（docs/SPEC/html/mockup-auth-pwd.html）。
//!
//! 主窗口（tbar 40 + term 540 + sbar 28 = 608 高）+ 会话浮层
//! rgba(236,255,244,.5)+blur6，居中 430 宽密码卡：标题 / sub(b 内联) /
//! 聚焦密码框(2px acc + 3px ring) / 指纹虚线卡 / 勾选保存行 /
//! 取消连接 + 连接↵ / 同框架注脚。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 608 };
pub const title = "mockup-auth-pwd";

const tok = mock.tok;

// HTML 局部色
const c_f6fbf8 = ui.Color.rgb(0xF6, 0xFB, 0xF8); // .fps 指纹卡底

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountBody(cx),
        try mountStatusBar(cx),
    });
}

// ── 标题栏（tbar 40） ─────────────────────────────────────────────

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
    // 激活页签：🔒 Bastion-01 (连接中…) ✕
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
    try tab.appendChild(cx.allocator, try ui.text(cx, "Bastion-01 (连接中…) ✕", .{
        .font_size = 12,
        .font_weight = 500,
        .color = tok.fg,
    }));
    try bar.appendChild(cx.allocator, tab);
    return bar;
}

// ── 终端区（term 540：两行日志 + 浮层 + 密码卡） ───────────────────

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
    const dim = tok.alpha(tok.fg, 140); // .td opacity .55 近似
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 正在连接 Bastion-01 (118.31.22.10:2222)…", .color = dim },
    }, .{}));
    try term.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "[ZeroWork] 主机密钥已核验 (known_hosts ✓) · 服务端要求密码认证", .color = dim },
    }, .{}));

    // .ov 浮层：absolute 显式 fill
    const ov = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = tok.alpha(tok.bg, 128), // rgba(236,255,244,.5)
        .glass = .{ .backdrop_blur = 6 },
        .z_index = 10,
        .flex_shrink = 0,
    }, .{});
    try ov.appendChild(cx.allocator, try mountCard(cx));
    try term.appendChild(cx.allocator, ov);
    return term;
}

/// 密码卡 .ac：430 宽 / 圆角 12 / rgba(248,255,251,.95) / 22/26 padding。
fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 430 },
        .direction = .column,
        .background = ui.Color.rgba(248, 255, 251, 242), // .95
        .border = .{ .width = 1, .color = tok.alpha(tok.acc, 26), .radius = 12 },
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(15, 23, 42, 36) },
        .padding = .{ .left = 26, .right = 26, .top = 22, .bottom = 22 },
        .flex_shrink = 0,
    }, .{});

    // 标题
    try card.appendChild(cx.allocator, try ui.text(cx, "🔑 需要密码 — Bastion-01", .{
        .font_size = 14,
        .font_weight = 600,
        .color = tok.fg,
        .line_height = 1.3,
    }));
    // sub 两行（b 内联：粗体深色 span 拼接）
    const sub = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .margin = .{ .top = 5, .right = 0, .bottom = 14, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try sub.appendChild(cx.allocator, try ui.text(cx, "服务器 ops_jumper@118.31.22.10:2222 要求交互式密码（password", .{
        .font_size = 11,
        .color = tok.fg2,
        .line_height = 1.5,
    }));
    try sub.appendChild(cx.allocator, try ui.text(cx, "auth；与 OTP 同一认证框架）", .{
        .font_size = 11,
        .color = tok.fg2,
        .line_height = 1.5,
    }));
    try card.appendChild(cx.allocator, sub);

    // 聚焦密码框 .pwf：1.5px acc + 3px ring(阴影) + 圆角 9
    const pwf = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 38 },
        .direction = .row,
        .align_items = .center,
        .gap = 9,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = tok.white,
        .border = .{ .width = 1.5, .color = tok.acc, .radius = 9 },
        .shadows = ui.ShadowList.of(&.{
            .{ .color = tok.alpha(tok.acc, 31), .blur = 0, .offset_x = 0, .offset_y = 0, .spread = 3 },
        }),
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try pwf.appendChild(cx.allocator, try ui.text(cx, "• • • • • • • • • •", .{
        .font_size = 14,
        .color = tok.fg,
        .use_monospace_font = true,
        .line_height = 1.2,
    }));
    try pwf.appendChild(cx.allocator, try ui.spacer(cx));
    try pwf.appendChild(cx.allocator, try ui.text(cx, "👁", .{ .font_size = 12, .color = tok.fg3 }));
    try card.appendChild(cx.allocator, pwf);

    // 指纹卡 .fps（虚线边以低透明实线近似）
    const fps = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 11, .right = 11, .top = 7, .bottom = 7 },
        .background = c_f6fbf8,
        .border = .{ .width = 1, .color = tok.alpha(tok.bd, 180), .radius = 8 },
        .margin = .{ .top = 0, .right = 0, .bottom = 10, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try fps.appendChild(cx.allocator, try ui.text(cx, "主机指纹（已信任）", .{
        .font_size = 10,
        .color = tok.fg2,
        .line_height = 1.6,
    }));
    try fps.appendChild(cx.allocator, try ui.text(cx, "ED25519 SHA256:xT4…9Qk2 · 首连时已 TOFU 确认 · 变更将红色警告", .{
        .font_size = 9.5,
        .color = tok.fg,
        .use_monospace_font = true,
        .line_height = 1.6,
    }));
    try card.appendChild(cx.allocator, fps);

    // 保存勾选行 .savr：勾选框 15² + 文本 + 蓝色「仅本次会话记住」
    const savr = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .center,
        .gap = 7,
        .flex_shrink = 0,
    }, .{});
    const cbx = try ui.box(cx, .{
        .width = .{ .px = 15 },
        .height = .{ .px = 15 },
        .align_items = .center,
        .justify = .center,
        .background = tok.acc,
        .border = .{ .width = 0, .color = tok.acc, .radius = 4 },
        .flex_shrink = 0,
    }, .{});
    try cbx.appendChild(cx.allocator, try ui.text(cx, "✓", .{
        .font_size = 10,
        .font_weight = 700,
        .color = tok.white,
    }));
    try savr.appendChild(cx.allocator, cbx);
    try savr.appendChild(cx.allocator, try ui.text(cx, "保存凭据到本地配置（明文，仅本机可读）· ", .{
        .font_size = 10.5,
        .color = tok.fg2,
        .line_height = 1.3,
    }));
    try savr.appendChild(cx.allocator, try ui.text(cx, "仅本次会话记住", .{
        .font_size = 10.5,
        .color = tok.acc,
        .line_height = 1.3,
    }));
    try card.appendChild(cx.allocator, savr);

    // 操作行 .oacts：居中 gap 10 margin-top 16
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
    try oacts.appendChild(cx.allocator, try obButton(cx, "连接 ↵", true));
    try card.appendChild(cx.allocator, oacts);

    // 同框架注脚 .km
    const km = try ui.box(cx, .{
        .width = .fill(),
        .direction = .row,
        .justify = .center,
        .margin = .{ .top = 12, .right = 0, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    try km.appendChild(cx.allocator, try ui.text(cx, "同框架还支持：私钥口令 · OTP 动态码 · 主机密钥首连确认", .{
        .font_size = 9.5,
        .color = tok.fg3,
        .line_height = 1.4,
    }));
    try card.appendChild(cx.allocator, km);
    return card;
}

/// 操作按钮 .ob：8/20 padding 圆角 8 字 12；p = 渐变白字 600。
fn obButton(cx: *ui.Cx, label: []const u8, primary: bool) !*ui.Node {
    const b = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 8 },
        .background = if (primary) ui.Color.TRANSPARENT else ui.Color.rgba(0, 0, 0, 8),
        .gradient = if (primary) .{ .from = tok.acc, .to = ui.Color.rgb(0x25, 0x63, 0xEB), .direction = .diagonal } else null,
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

// ── 状态栏（sbar 28：黄点 + 连接中文案） ──────────────────────────

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
    try bar.appendChild(cx.allocator, try ui.text(cx, "连接中: 等待密码输入", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    return bar;
}
