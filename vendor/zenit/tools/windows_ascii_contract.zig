//! Actual UI -> paint table -> native pixels; no foreground activation.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
var label: *ui.Node = undefined;
const sample = "H H H H H H H H H H H H";
fn require(ok: bool) !void {
    if (!ok) return error.FixedAsciiContractFailed;
}
fn mount(cx: *ui.Cx, _: *ui.Scope) !*ui.Node {
    const root = try ui.box(cx, .{ .padding = ui.Padding.all(8) }, .{});
    label = try ui.text(cx, sample, .{ .font_size = 20, .color = ui.Color.rgb(0, 0, 0) });
    try root.appendChild(cx.allocator, label);
    return root;
}
fn pixels(app: *App, path: [:0]const u8, expected_spacing: ?f32, expected_count: ?usize, expected_span: ?f32) !u64 {
    try require(try app.painter.captureBmp(path));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.cx.io, path, app.allocator, .limited(32 * 1024 * 1024));
    defer app.allocator.free(bytes);
    try require(bytes.len >= 54 and std.mem.eql(u8, bytes[0..2], "BM"));
    const start = std.mem.readInt(u32, bytes[10..14], .little);
    const width = std.mem.readInt(u32, bytes[18..22], .little);
    const signed_height = std.mem.readInt(i32, bytes[22..26], .little);
    const height: usize = @intCast(@abs(signed_height));
    try require(std.mem.readInt(u16, bytes[28..30], .little) == 32);
    try require(start + @as(usize, width) * height * 4 <= bytes.len);
    var centers: [64]f32 = undefined;
    var count: usize = 0;
    var left: ?usize = null;
    for (0..width + 1) |x| {
        var ink = false;
        if (x < width) for (0..height) |y| {
            const p = start + (y * width + x) * 4;
            if (bytes[p] < 180 and bytes[p + 1] < 180 and bytes[p + 2] < 180) {
                ink = true;
                break;
            }
        };
        if (ink) {
            if (left == null) left = x;
        } else if (left) |l| {
            try require(count < centers.len);
            centers[count] = @as(f32, @floatFromInt(l + x - 1)) / 2;
            count += 1;
            left = null;
        }
    }
    if (expected_count) |n| try require(count == n);
    if (expected_spacing) |spacing| {
        std.log.info("ASCII pixel centers spacing={d}: {any}", .{ spacing, centers[0..count] });
        try require(count >= 2);
        for (1..count) |i| try require(@abs(centers[i] - centers[0] - @as(f32, @floatFromInt(i)) * spacing) <= 2);
    }
    if (expected_span) |span| {
        std.log.info("ASCII ligature pixel centers span={d}: {any}", .{ span, centers[0..count] });
        try require(count >= 2 and @abs(centers[count - 1] - centers[0] - span) <= 2);
    }
    return std.hash.Wyhash.hash(0, bytes[start..]);
}
pub fn run(io: std.Io) !void {
    var stage: []const u8 = "init";
    errdefer std.log.err("Windows fixed ASCII stage={s}", .{stage});
    const before = Window.liveWindowCount();
    const foreground = GetForegroundWindow();
    const alloc = std.heap.page_allocator;
    const temp = try @import("zenit_environment").getOwned(alloc, "TEMP");
    defer alloc.free(temp);
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}\\zenit-ascii-{x}.bmp", .{ temp, randomId(io) }, 0);
    defer alloc.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const font_path = try std.fmt.allocPrintSentinel(alloc, "{s}\\zenit-ascii-ligature-{x}.ttf", .{ temp, randomId(io) }, 0);
    defer alloc.free(font_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = font_path, .data = @embedFile("fixtures/fonts/Lora-Regular.ttf") });
    defer std.Io.Dir.cwd().deleteFile(io, font_path) catch {};
    {
        const app = try App.init(alloc, .{ .io = io, .window = .{ .width = 640, .height = 100 }, .clear_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
        defer app.deinit();
        try app.mount(mount);
        stage = "marker-spacing";
        for ([_]f32{ 12, 24, 16, 24 }) |cell| {
            label.setText(.{ .content = sample, .font_size = 20, .font_weight = 700, .use_italic_font = true, .use_monospace_font = true, .monospace_char_width = cell, .color = ui.Color.rgb(0, 0, 0) });
            try app.frame();
            _ = try pixels(app, path, 2 * cell * app.win.getScaleFactor(), 12, null);
        }
        // The same cached natural layout must not acquire fixed spacing unless
        // both monospace and all-ASCII preconditions hold.
        stage = "non-mono-CJK-guards";
        for ([_][]const u8{ sample, "H H 中文 H H" }, 0..) |content, index| {
            var previous: ?u64 = null;
            for ([_]f32{ 12, 24 }) |cell| {
                label.setText(.{ .content = content, .font_size = 20, .use_monospace_font = index != 0, .monospace_char_width = cell, .color = ui.Color.rgb(0, 0, 0) });
                try app.frame();
                const hash = try pixels(app, path, null, null, null);
                if (previous) |p| try require(p == hash);
                previous = hash;
            }
        }
        stage = "private-font-shaping";
        const font = try app.font_system.loadFont(font_path, 20);
        defer font.deinit();
        var selector = @FieldType(App, "font_selector"){ .small = font, .medium = font, .large = font };
        selector.initDerivedCache(alloc);
        defer selector.deinitDerivedCache();
        app.setFontSelector(&selector);
        defer app.resetFontSelector();
        const ligatures = "H ffi ffi H";
        const shaped = try app.cx.text.shapeText(.{ .text = ligatures, .font_family = "system", .font_size = 20, .use_monospace = true });
        std.log.info("ASCII private-font shaped glyphs={d}, source bytes={d}", .{ shaped.glyphs.len, ligatures.len });
        try require(shaped.glyphs.len < ligatures.len);
        stage = "ligature-pixels";
        for ([_]f32{ 16, 24 }) |cell| {
            label.setText(.{ .content = ligatures, .font_size = 20, .use_monospace_font = true, .monospace_char_width = cell, .color = ui.Color.rgb(0, 0, 0) });
            try app.frame();
            _ = try pixels(app, path, null, null, 10 * cell * app.win.getScaleFactor());
        }
        try require(GetForegroundWindow() == foreground);
    }
    try require(Window.liveWindowCount() == before and GetForegroundWindow() == foreground);
    std.log.info("Windows fixed ASCII pixels: 12 marker columns at 12/24/16/24px cells, bold italic, cache reuse, non-mono/CJK guards and private-font ligature endpoint cells PASS", .{});
}

fn randomId(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}
