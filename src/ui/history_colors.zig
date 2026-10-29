//! Resolve retained VT color semantics at paint time. Packed wire/search RGB
//! is a cache: default and indexed cells follow the current global theme,
//! while an explicit truecolor cell retains its recorded RGB.
const std = @import("std");
const vt = @import("../vt/snapshot.zig");
const Theme = @import("../vt/theme.zig").Theme;
const Span = @import("../vt/search_snapshot.zig").Span;

pub const Style = struct { color: u32, bg: u32, flags: u32 };

pub const PaintedFrame = struct {
    frame: @import("../vt/text_frame.zig").Frame,
    owned: []@import("../vt/text_frame.zig").WireSpan = &.{},
    pub fn deinit(self: PaintedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.owned);
    }
};
pub fn frame(allocator: std.mem.Allocator, entry: @import("history_replay.zig").Timeline.Entry, theme: ?Theme) !PaintedFrame {
    var result: PaintedFrame = .{ .frame = @import("../vt/text_frame.zig").decode(entry.wire) orelse return error.InvalidFrame };
    if (entry.color_runs.len == 0 or theme == null) return result;
    result.owned = try allocator.alloc(@import("../vt/text_frame.zig").WireSpan, entry.color_runs.len);
    var count: usize = 0;
    for (entry.color_runs) |run| {
        const style = resolve(.{ .start = run.start, .end = run.end, .row = 0, .col = 0, .width = 1, .flags = (run.cell.attributes & 3) | (if (run.cell.underline != 0) @as(u32, 4) else 0), .native_cell = run.cell }, run.kind, theme, entry.reverse_colors);
        if (style.color == 0 and style.bg == 0 and style.flags == 0) continue;
        result.owned[count] = .{ .start = run.start, .end = run.end, .color = style.color, .bg = style.bg, .flags = style.flags };
        count += 1;
    }
    result.frame.spans = result.owned[0..count];
    return result;
}

pub fn resolve(span: Span, application_kind: u8, theme: ?Theme, reverse_colors: bool) Style {
    if (application_kind != 0) {
        const colors = @import("builtin_records_styles.zig").colors();
        const ink = if (application_kind <= 3) rgba(colors[application_kind - 1]) else pack(@import("app_theme.zig").current().fg_2);
        return .{ .color = ink, .bg = 0, .flags = span.flags };
    }
    const cell = span.native_cell orelse return .{ .color = span.color, .bg = span.bg, .flags = span.flags };
    const current = theme orelse return .{ .color = span.color, .bg = span.bg, .flags = span.flags };
    const default_fg = if (reverse_colors) current.background else current.foreground;
    const default_bg = if (reverse_colors) current.foreground else current.background;
    var fg = color(cell.foreground, current);
    var bg = color(cell.background, current);
    if (reverse_colors) {
        if (fg == 0) fg = default_fg;
        if (bg == 0) bg = default_bg;
    }
    if (cell.attributes & (1 << 4) != 0) {
        const old = fg;
        fg = if (bg == 0) default_bg else bg;
        bg = if (old == 0) default_fg else old;
    }
    if (cell.attributes & (1 << 6) != 0) fg = ((if (fg == 0) default_fg else fg) & 0xffffff00) | 127;
    if (cell.attributes & (1 << 7) != 0) fg = 0x00000100;
    return .{ .color = fg, .bg = bg, .flags = span.flags };
}

fn color(value: vt.Color, theme: Theme) u32 {
    return switch (value) {
        .default => 0,
        .rgb => |rgb| rgba(rgb),
        .ansi => |index| theme.ansi[index],
        .indexed => |index| if (index < 16) theme.ansi[index] else indexed(index),
    };
}
fn indexed(index: u8) u32 {
    if (index >= 232) return rgba(@as(u24, 8 + @as(u16, index - 232) * 10) * 0x010101);
    const cube = index - 16;
    const levels = [_]u24{ 0, 95, 135, 175, 215, 255 };
    return rgba((levels[cube / 36] << 16) | (levels[cube / 6 % 6] << 8) | levels[cube % 6]);
}
fn rgba(rgb: u24) u32 {
    return (@as(u32, rgb) << 8) | 255;
}
fn pack(c: @import("ui").Color) u32 {
    return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | c.a;
}

test "history colors resolve current default indexed palette and keep explicit truecolor" {
    const a = std.testing.allocator;
    const cast = "{\"version\":2,\"width\":80,\"height\":3}\n[0,\"o\",\"default \\u001b[31mansi \\u001b[38;5;1mindex \\u001b[38;5;196mred256 \\u001b[38;2;17;34;51mtruecolor\\u001b[0m\"]\n";
    var timeline = try @import("history_cast.zig").loadWithDisplay(a, cast, null, .{ .colors = .{ .foreground = 0xeeeeeeff, .background = 0x101018ff, .cursor = 0xeeeeeeff, .selection = 0x6366f14d, .ansi = @splat(0x123456ff) } });
    defer timeline.deinit();
    const document = timeline.latest().?.search.?;
    var theme: Theme = .{ .revision = 1, .foreground = 0x111111ff, .background = 0xfafafaff, .cursor = 0, .selection = 0, .ansi = @splat(0) };
    theme.ansi[1] = 0xaa0011ff;
    const default = document.spanAt(std.mem.indexOf(u8, document.text, "default").?).?;
    const ansi = document.spanAt(std.mem.indexOf(u8, document.text, "ansi").?).?;
    const index = document.spanAt(std.mem.indexOf(u8, document.text, "index").?).?;
    const red256 = document.spanAt(std.mem.indexOf(u8, document.text, "red256").?).?;
    const literal = document.spanAt(std.mem.indexOf(u8, document.text, "truecolor").?).?;
    try std.testing.expect(ansi.color != 0x123456ff); // manifest palette was not installed in the decoder
    try std.testing.expectEqual(@as(u32, 0), resolve(default, 0, theme, false).color);
    try std.testing.expectEqual(theme.ansi[1], resolve(ansi, 0, theme, false).color);
    try std.testing.expectEqual(theme.ansi[1], resolve(index, 0, theme, false).color);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), resolve(red256, 0, theme, false).color);
    try std.testing.expectEqual(@as(u32, 0x112233ff), resolve(literal, 0, theme, false).color);
    // The same retained document follows a second publication without decoding
    // again or turning a literal RGB that happens to match ANSI into an index.
    theme.revision = 2;
    theme.ansi[1] = 0x112233ff;
    try std.testing.expectEqual(theme.ansi[1], resolve(ansi, 0, theme, false).color);
    theme.ansi[1] = 0x44bb66ff;
    try std.testing.expectEqual(theme.ansi[1], resolve(index, 0, theme, false).color);
    try std.testing.expectEqual(@as(u32, 0x112233ff), resolve(literal, 0, theme, false).color);
}

test "history colors preserve inverse faint hidden and explicit backgrounds" {
    const theme: Theme = .{ .revision = 1, .foreground = 0xeeeeeeff, .background = 0x101018ff, .cursor = 0, .selection = 0, .ansi = @splat(0x887766ff) };
    var span: Span = .{ .start = 0, .end = 1, .row = 0, .col = 0, .width = 1, .native_cell = .{ .attributes = 1 << 4 } };
    const inverse = resolve(span, 0, theme, false);
    try std.testing.expectEqual(theme.background, inverse.color);
    try std.testing.expectEqual(theme.foreground, inverse.bg);
    span.native_cell = .{ .foreground = .{ .rgb = 0x000000 }, .background = .{ .rgb = 0xffffff } };
    try std.testing.expectEqual(@as(u32, 0x000000ff), resolve(span, 0, theme, false).color);
    try std.testing.expectEqual(@as(u32, 0xffffffff), resolve(span, 0, theme, false).bg);
    span.native_cell.?.attributes = 1 << 6;
    try std.testing.expectEqual(@as(u32, 0x0000007f), resolve(span, 0, theme, false).color);
    span.native_cell.?.attributes = 1 << 7;
    try std.testing.expectEqual(@as(u32, 0x00000100), resolve(span, 0, theme, false).color);
}

test "history archive follows global theme without changing font reading position or literal RGB" {
    const ui = @import("ui");
    const app_theme = @import("app_theme.zig");
    const View = @import("terminal_view.zig").TerminalViewNode;
    const old_theme = app_theme.currentName();
    defer app_theme.select(old_theme);
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 280);
    var view = try View.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    view.setTypography(17, 1.6, 400);
    view.history.deinit();
    var recording: std.ArrayList(u8) = .empty;
    defer recording.deinit(a);
    try recording.appendSlice(a, "{\"version\":2,\"width\":80,\"height\":4}\n[0,\"o\",\"");
    for (0..20) |_| try recording.appendSlice(a, "default \\u001b[31mansi \\u001b[38;5;1mindex \\u001b[38;2;17;34;51mliteral\\u001b[0m\\r\\n");
    try recording.appendSlice(a, "\"]\n");
    view.history = try @import("history_cast.zig").loadWithDisplay(a, recording.items, null, .{ .colors = .{ .foreground = 0xeeeeeeff, .background = 0x101018ff, .cursor = 0xeeeeeeff, .selection = 0x6366f14d, .ansi = @splat(0x123456ff) } });
    view.bindArchived();
    cx.layout();
    try std.testing.expect(view.openHistory());
    view.history_reading.?.scroll(-7.5);
    const offset = view.history_reading.?.offset;
    const position = view.history_reading.?.position;
    view.selection.begin(.{ .row = 0, .col = 1 });
    view.selection.update(.{ .row = 0, .col = 5 });
    view.selection.endDrag();
    const selected = view.selection;
    for ([_]app_theme.Name{ .dark, .light, .sauber }, 0..) |name, i| {
        app_theme.select(name);
        const current = app_theme.current();
        var next: Theme = .{ .revision = i + 1, .foreground = pack(current.fg_1), .background = pack(current.terminal.withAlpha(255)), .cursor = pack(current.accent), .selection = pack(current.selection), .ansi = @splat(0) };
        next.ansi[1] = (0x770011ff + @as(u32, @intCast(i)) * 0x11220000);
        try view.setTerminalTheme(next);
        try std.testing.expectEqual(current.fg_1, view.base_fg);
        try std.testing.expectEqual(@as(f32, 17), view.terminal_font_size);
        try std.testing.expectEqual(@as(f32, 1.6), view.terminal_line_height);
        try std.testing.expectEqual(offset, view.history_reading.?.offset);
        try std.testing.expectEqualDeep(position, view.history_reading.?.position);
        try std.testing.expectEqualDeep(selected, view.selection);
        const row = view.row_nodes[0].?;
        const props = row.getText().?;
        try std.testing.expectEqual(next.foreground, pack(inkAt(props, "default")));
        try std.testing.expectEqual(next.ansi[1], pack(inkAt(props, "ansi")));
        try std.testing.expectEqual(next.ansi[1], pack(inkAt(props, "index")));
        try std.testing.expectEqual(@as(u32, 0x112233ff), pack(inkAt(props, "literal")));
        try std.testing.expectEqual(@as(f32, 17), props.font_size);
    }
}

fn inkAt(props: @import("ui").types.TextProps, needle: []const u8) @import("ui").Color {
    const index = std.mem.indexOf(u8, props.content, needle) orelse unreachable;
    for (props.spans) |span| if (index >= span.start and index < span.end) return span.color orelse props.color;
    return props.color;
}

test "history viewport-only log keeps default indexed and literal semantics through clone trim and theme change" {
    const ui = @import("ui");
    const View = @import("terminal_view.zig").TerminalViewNode;
    const Timeline = @import("history_replay.zig").Timeline;
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 3, 80);
    defer adapter.destroy();
    _ = try adapter.feed("default \x1b[31mansi \x1b[38;2;204;102;102mliteral\x1b[0m");
    var projection = try adapter.copyProjection(a);
    defer projection.deinit(a);
    var original = Timeline.init(a, 1024 * 1024);
    defer original.deinit();
    try std.testing.expect(try original.appendProjectionChanged(1, &projection));
    try std.testing.expect(original.latest().?.search == null);
    try std.testing.expect(original.latest().?.color_runs.len > 0);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 280);
    var view = try View.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    view.history.deinit();
    view.history = try original.clone();
    view.bindArchived();
    cx.layout();
    try std.testing.expect(view.openHistory());
    var theme: Theme = .{ .revision = 1, .foreground = 0x111111ff, .background = 0xfafafaff, .cursor = 0, .selection = 0, .ansi = @splat(0x225588ff) };
    for ([_]u32{ 0x225588ff, 0x44bb66ff }) |red| {
        theme.revision += 1;
        theme.ansi[1] = red;
        try view.setTerminalTheme(theme);
        const props = view.row_nodes[0].?.getText().?;
        try std.testing.expectEqual(theme.foreground, pack(inkAt(props, "default")));
        try std.testing.expectEqual(red, pack(inkAt(props, "ansi")));
        try std.testing.expectEqual(@as(u32, 0xcc6666ff), pack(inkAt(props, "literal")));
    }
    // Equal baked RGB is not equal color semantics. Replacing ANSI with an
    // explicit RGB of that same value must remain a distinct history frame.
    const cells = @constCast(projection.cells);
    for (cells) |*cell| if (cell.foreground == .ansi) {
        const index = cell.foreground.ansi;
        const literal = projection.colors.palette[index];
        cell.foreground = .{ .rgb = literal };
    };
    try std.testing.expect(try original.appendProjectionChanged(2, &projection));
    try std.testing.expectEqual(@as(usize, 2), original.frames.items.len);
    try original.replaceLatestProjection(&projection);
    original.limit = 1;
    original.trim();
    try std.testing.expectEqual(@as(usize, 1), original.frames.items.len);
    const painted = try frame(a, original.latest().?, theme);
    defer painted.deinit(a);
    try std.testing.expect(painted.frame.spans.len > 0);
    // New color run allocations are part of the original bounded budget and
    // all error paths release them, including clone and replacement failure.
    try std.testing.checkAllAllocationFailures(a, captureClone, .{&projection});
}

fn captureClone(allocator: std.mem.Allocator, projection: *const vt.Projection) !void {
    const Timeline = @import("history_replay.zig").Timeline;
    var timeline = Timeline.init(allocator, 1024 * 1024);
    defer timeline.deinit();
    try timeline.appendProjection(1, projection);
    var clone = try timeline.clone();
    defer clone.deinit();
    try clone.replaceLatestProjection(projection);
}
