const ui = @import("ui");
const mock = @import("mockups/common.zig");
const catalog = @import("command_catalog.zig");
const tok = mock.tok;
const c_line5 = ui.Color.rgba(0, 0, 0, 13);

pub fn mountCard(cx: *ui.Cx) !*ui.Node {
    const card = try ui.box(cx, .{
        .width = .{ .px = 580 },
        .direction = .column,
        .background = ui.Color.rgba(0xF8, 0xFF, 0xFB, 242), // rgba(248,255,251,.95)
        .border = .{ .width = 0, .color = tok.alpha(tok.acc, 26), .radius = 12 }, // rgba(19,69,246,.1)
        .shadow = .{ .blur = 44, .offset_y = 16, .color = ui.Color.rgba(0x0F, 0x17, 0x2A, 36) }, // rgba(15,23,42,.14)
        .glass = .{ .backdrop_blur = 24 },
        .z_index = 20,
        .overflow = .hidden,
    }, .{});

    // 头部（ch：padding 13 18，高 ~46，字 13·600 + 右注 10 fg3）
    const ch = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 46 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .border = .{ .width = 0, .color = c_line5, .radius = 0 },
        .flex_shrink = 0,
    }, .{});
    try ch.appendChild(cx.allocator, try ui.text(cx, "❓ 内置指令速查", .{
        .font_size = 13,
        .font_weight = 600,
        .color = tok.fg,
    }));
    try ch.appendChild(cx.allocator, try ui.spacer(cx));
    try ch.appendChild(cx.allocator, try ui.text(cx, "Esc 关闭", .{
        .font_size = 10,
        .font_weight = 400,
        .color = tok.fg3,
    }));
    try card.appendChild(cx.allocator, ch);

    // 14 行速查（容器 padding 5 0；行高 ~28.5）
    const rows = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .padding = .{ .left = 0, .right = 0, .top = 5, .bottom = 5 },
    }, .{});
    for (catalog.entries) |c| {
        try rows.appendChild(cx.allocator, try cmdRow(cx, c));
    }
    try card.appendChild(cx.allocator, rows);

    // 脚注（cf：padding 9 18，两行 10px lh1.6）
    const cf = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 0,
        .padding = .{ .left = 18, .right = 18, .top = 9, .bottom = 9 },
        .border = .{ .width = 0, .color = c_line5, .radius = 0 },
        .flex_shrink = 0,
    }, .{});
    try cf.appendChild(cx.allocator, try ui.text(cx, "在空命令行输入 @ 查看指令。", .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.6,
    }));
    try cf.appendChild(cx.allocator, try ui.text(cx, "输入 @@ 可发送普通 @ 字符。", .{
        .font_size = 10,
        .color = tok.fg3,
        .line_height = 1.6,
    }));
    try card.appendChild(cx.allocator, cf);
    return card;
}

/// 速查行：ic(20) + cmd(150 mono 11·600 acc) + ds(11.5 fg2)。
fn cmdRow(cx: *ui.Cx, c: catalog.Entry) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 11,
        .padding = .{ .left = 18, .right = 18, .top = 0, .bottom = 0 },
        .flex_shrink = 0,
    }, .{});
    const ic = try ui.box(cx, .{
        .width = .{ .px = 20 },
        .align_items = .center,
        .flex_shrink = 0,
    }, .{});
    try ic.appendChild(cx.allocator, try ui.text(cx, c.icon, .{ .font_size = 12, .color = tok.fg }));
    try row.appendChild(cx.allocator, ic);
    const cmd_col = try ui.box(cx, .{
        .width = .{ .px = 150 },
        .direction = .row,
        .flex_shrink = 0,
    }, .{});
    try cmd_col.appendChild(cx.allocator, try ui.text(cx, c.usage, .{
        .font_size = 11,
        .font_weight = 600,
        .color = tok.acc,
        .use_monospace_font = true,
    }));
    try row.appendChild(cx.allocator, cmd_col);
    try row.appendChild(cx.allocator, try ui.text(cx, c.description, .{
        .font_size = 11.5,
        .color = tok.fg2,
    }));
    return row;
}
