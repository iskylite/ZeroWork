//! V0.5 editor probe for the document region in docs/UI_V4/notes/compact-editing.svg.
//! Run with zig build mockup -Dmockup=notes-editor -Dtest-mode=true.
const std = @import("std");
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

const Preview = struct {
    cx: *ui.Cx,
    source: *ui.Signal([]const u8),
    rendered: *ui.Signal([]const u8),
    timer: ?u64 = null,

    fn landed(self: *Preview, _: []const u8) void {
        self.cancel();
        self.timer = self.cx.setTimer(120 * std.time.ns_per_ms, refresh, self) catch {
            refresh(self);
            return;
        };
    }

    fn refresh(raw: ?*anyopaque) void {
        const self: *Preview = @ptrCast(@alignCast(raw.?));
        self.timer = null;
        const source = self.source.peek();
        // The probe exercises inline code and emphasis. Production block
        // classification will decide which edits need a rendered preview.
        self.rendered.set(if (std.mem.indexOfAny(u8, source, "`*") != null) source else "");
        self.cx.requestRedraw();
    }

    fn cancel(self: *Preview) void {
        if (self.timer) |timer| self.cx.clearTimer(timer);
        self.timer = null;
    }
};

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

    const preview = try scope.createState(Preview, .{
        .cx = cx,
        .source = try scope.createText(sample, .{}),
        .rendered = try scope.createText(sample, .{}),
    });
    try scope.onCleanup(Preview, preview, Preview.cancel);
    const input = try ui.widgets.Textarea(.{
        .value = preview.source,
        .borderless = true,
        .rows = 4,
        .on_change = cx.on(Preview, preview, Preview.landed),
    }).mountResult(scope, cx);
    input.input.meta.ownership.meta.test_id = "notes.editor.active";
    const editor_surface = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 80 },
        .background = ui.arb.hex(0xf5f5f8),
        .border = .{ .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try editor_surface.appendChild(cx.allocator, input.wrapper);
    try doc.appendChild(cx.allocator, editor_surface);

    const body = try ui.box(cx, .{
        .width = .fill(),
        .direction = .column,
        .gap = 18,
        .padding = .{ .left = 8, .right = 8, .top = 0, .bottom = 0 },
    }, .{});
    body.style.flex_shrink = 0;
    try doc.appendChild(cx.allocator, body);
    const markdown = try ui.widgets.Markdown(.{
        .text = preview.rendered,
        .options = .{
            .base_font_size = 14,
            .code_font_size = 13,
            .text_color = ui.arb.hex(0x18181b),
            .code_color = ui.arb.hex(0x4f5ed9),
            .code_bg = ui.arb.hex(0xf1f1f4),
            .paragraph_gap = 8,
        },
    }).mount(scope, cx);
    markdown.meta.ownership.meta.test_id = "notes.editor.preview";
    try body.appendChild(cx.allocator, markdown);
    const code = try ui.widgets.Markdown(.{
        .text = code_sample,
        .options = .{ .code_font_size = 13.5 },
    }).mount(scope, cx);
    try body.appendChild(cx.allocator, code);
    const tail = try ui.text(cx, "检查日志", .{ .font_size = 17, .font_weight = 600, .color = ui.arb.hex(0x18181b) });
    tail.meta.ownership.meta.test_id = "notes.document.tail";
    try body.appendChild(cx.allocator, tail);
    try body.appendChild(cx.allocator, try ui.text(cx, "重新加载服务后，核对应用日志与访问日志。", .{
        .font_size = 14,
        .color = ui.arb.hex(0x18181b),
    }));
    return scroll.container;
}
