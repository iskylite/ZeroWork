//! Live Markdown editor probe for the document region in docs/UI_V4/notes/compact-editing.svg.
//! Run with zig build mockup -Dmockup=notes-editor -Dtest-mode=true.
const ui = @import("ui");

pub const window_size = .{ .width = 592, .height = 408 };
pub const title = "ZeroWork · 笔记编辑";

const sample =
    \\先运行 `nginx -t`，确认配置检查通过。
    \\
    \\**重新加载服务前**，保留旧证书与配置。
;
const code_sample =
    \\```sh
    \\nginx -t
    \\systemctl reload nginx
    \\```
;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    cx.setTheme(&ui.theme.light);
    const scroll = try ui.widgets.ScrollArea(.{
        .padding = .{ .left = 16, .right = 16, .top = 74, .bottom = 12 },
        .background = ui.arb.hex(0xffffff),
        .rubber_band_y = false,
    }).mount(scope, cx);
    scroll.container.meta.ownership.meta.test_id = "notes.document.scroll";
    scroll.content.style.flex_shrink = 0;

    const doc = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 12,
    }, .{});
    doc.style.flex_shrink = 0;
    try scroll.content.appendChild(cx.allocator, doc);
    const header = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 14,
        .padding = .{ .left = 8, .right = 8, .top = 0, .bottom = 0 },
    }, .{});
    try doc.appendChild(cx.allocator, header);
    try header.appendChild(cx.allocator, try ui.text(cx, "生产环境证书更新", .{
        .font_size = 24,
        .font_weight = 650,
        .color = ui.arb.hex(0x18181b),
    }));
    try header.appendChild(cx.allocator, try ui.text(cx, "验证与回滚", .{
        .font_size = 17,
        .font_weight = 600,
        .color = ui.arb.hex(0x18181b),
    }));

    const input = try ui.widgets.Textarea(.{
        .value = sample,
        .borderless = true,
        .rows = 3,
        .live_markdown = ui.widgets.MarkdownOptions{
            .base_font_size = 14,
            .text_color = ui.arb.hex(0x18181b),
            .code_color = ui.arb.hex(0x18181b),
            .code_bg = ui.arb.hex(0xf1f1f4),
            .rule_color = ui.arb.hex(0x5b5b65),
            .standalone_tasks = true,
        },
    }).mountResult(scope, cx);
    input.input.meta.ownership.meta.test_id = "notes.editor.active";
    input.wrapper.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
    try doc.appendChild(cx.allocator, input.wrapper);

    const code = try ui.widgets.Markdown(.{
        .text = code_sample,
        .options = .{ .code_font_size = 13.5 },
    }).mount(scope, cx);
    try doc.appendChild(cx.allocator, code);
    const tail = try ui.text(cx, "检查日志", .{ .font_size = 17, .font_weight = 600, .color = ui.arb.hex(0x18181b) });
    tail.meta.ownership.meta.test_id = "notes.document.tail";
    try doc.appendChild(cx.allocator, tail);
    try doc.appendChild(cx.allocator, try ui.text(cx, "重新加载服务后，核对应用日志与访问日志。", .{
        .font_size = 14,
        .color = ui.arb.hex(0x18181b),
    }));
    return scroll.container;
}
