//! Reuse the exact App allocation after quit, without relying on zeroed pages.
const std = @import("std");
const ui = @import("ui");
extern fn zenit_d3d11_contract_clear_color(*anyopaque, *[4]f32) void;
extern fn zenit_d3d11_probe_set_clear_color(*anyopaque, f32, f32, f32, f32) void;
extern fn zenit_d3d11_contract_last_text_font(*anyopaque) ?*anyopaque;
extern fn zenit_dwrite_font_identity(*anyopaque) u64;
const render = @import("render");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern fn zenit_d3d11_contract_render_font(*anyopaque, ?*anyopaque, [*]const u8, u32) c_int;
extern fn zenit_d3d11_contract_font_width(*anyopaque, *anyopaque, [*]const u8, u32, f32) f32;
extern fn zenit_d3d11_contract_text_width(*anyopaque, [*]const u8, u32, f32) f32;
fn require(ok: bool) !void {
    if (!ok) return error.AppFontConfigContractFailed;
}
fn fontWidth(app: *App) !f32 {
    const sample = "iiiiWWWW font configuration";
    const expected = app.fonts[0].measureWidth(sample);
    const shaped = try app.cx.text.shapeText(.{ .text = sample, .font_family = "system", .font_size = app.fonts[0].pixelSize() });
    const native = zenit_d3d11_contract_text_width(app.painter.native, sample.ptr, sample.len, app.fonts[0].pixelSize());
    try require(expected > 0 and @abs(shaped.total_advance - expected) < 0.01 and @abs(native - expected) < 0.01);
    return expected;
}

pub const ReusedAllocator = struct {
    storage: [@sizeOf(App)]u8 align(@alignOf(App)) = @as([@sizeOf(App)]u8, @splat(1)),
    in_use: bool = false,
    app_allocations: usize = 0,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!self.in_use and len == @sizeOf(App) and alignment.toByteUnits() == @alignOf(App)) {
            self.in_use = true;
            self.app_allocations += 1;
            return &self.storage;
        }
        return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (memory.ptr == @as([*]u8, &self.storage)) {
            self.in_use = false;
            return;
        }
        std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    }

    pub fn beforeReuse(self: *@This(), io: std.Io) !void {
        try @import("windows_window_contract.zig").runInitialGeometry();
        const before = Window.liveWindowCount();
        const foreground = GetForegroundWindow();
        try @import("windows_alert_contract.zig").run();
        if (App.init(self.allocator(), .{ .io = io, .font = .{ .small_size = 0 } })) |unexpected| {
            unexpected.deinit();
            return error.AppFontConfigContractFailed;
        } else |err| try require(err == error.InvalidFontSize);
        try require(Window.liveWindowCount() == before and !self.in_use);
        try @import("windows_window_contract.zig").runCustom(io);
        {
            var family = [_]u8{ 'C', 'o', 'u', 'r', 'i', 'e', 'r', ' ', 'N', 'e', 'w' };
            const previous = try App.init(self.allocator(), .{
                .io = io,
                .window = .{ .title = "Zenit startup allocation contract" },
                .font = .{ .small_size = 17, .medium_size = 23, .large_size = 31, .fallback_families = &.{ "__Zenit_missing_font__", &family } },
            });
            defer previous.deinit();
            try initialized(previous);
            @memset(&family, 'x'); // Config lifetime must not own the resolved family.
            try require(std.mem.eql(u8, previous.resolved_font_family, "Courier New"));
            for (previous.fonts, [_]f32{ 17, 23, 31 }) |font, size| try require(font.pixelSize() == size and std.mem.eql(u8, font.family, "Courier New"));
            const courier_width = try fontWidth(previous);
            {
                const other = try App.init(std.heap.page_allocator, .{ .io = io, .font = .{ .small_size = 17, .fallback_families = &.{"Arial"} } });
                defer other.deinit();
                const arial_width = try fontWidth(other);
                try require(@abs(arial_width - courier_width) > 1);
                try require(@abs(try fontWidth(previous) - courier_width) < 0.01);
            }
            {
                const fallback = try App.init(std.heap.page_allocator, .{ .io = io, .font = .{ .fallback_families = &.{"__Zenit_missing_font__"} } });
                defer fallback.deinit();
                _ = try fontWidth(fallback);
                try require(std.mem.eql(u8, fallback.resolved_font_family, "system"));
            }
            try require(GetForegroundWindow() == foreground);
            if (Window.liveWindowCount() != before + 1) return error.AppInitContractFailed;
            previous.quit();
            if (!previous.should_quit) return error.AppInitContractFailed;
        }
        if (self.in_use or Window.liveWindowCount() != before) return error.AppInitContractFailed;
    }

    pub fn afterReuse(self: *@This(), app: *App) !void {
        try initialized(app);
        if (self.app_allocations != 2 or @intFromPtr(app) != @intFromPtr(&self.storage)) return error.AppInitContractFailed;
        try require(std.mem.eql(u8, app.resolved_font_family, "Segoe UI"));
        _ = try fontWidth(app);
        try externalFonts(app);
        try registryFonts(app.cx.io);
        try @import("windows_open_file_contract.zig").run(app);
        try @import("windows_focus_contract.zig").run(app.cx.io);
        try @import("windows_ascii_contract.zig").run(app.cx.io);
        try @import("windows_font_paint_contract.zig").run(app.cx.io);
        std.log.info("Windows font config contract: fallback, owned family, slots, shaping/native widths and window isolation PASS", .{});
        std.log.info("Windows App init contract: nonzero allocation and quit/reuse PASS", .{});
    }
    fn initialized(app: *App) !void {
        // An ordinary read of an uninitialized bool can be optimized away.
        // Check stored bytes so this contract can detect an omitted write.
        const bytes: [*]const volatile u8 = @ptrCast(app);
        inline for (.{ "should_quit", "native_frame_active", "native_redraw_pending", "in_native_callback" }) |field| {
            const value = bytes[@offsetOf(App, field)];
            if (value != 0) {
                std.log.err("Windows App init field {s} has stored byte 0x{x}", .{ field, value });
                return error.AppInitContractFailed;
            }
        }
    }
};

fn externalFonts(app: *App) !void {
    const allocator = app.allocator;
    const temp = try @import("zenit_environment").getOwned(allocator, "TEMP");
    defer allocator.free(temp);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}\\zenit-selector-字体-{x}.ttf", .{ temp, randomId(app.cx.io) }, 0);
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(app.cx.io, .{ .sub_path = path, .data = @embedFile("fixtures/fonts/Lora-Regular.ttf") });
    defer std.Io.Dir.cwd().deleteFile(app.cx.io, path) catch {};
    const font = try app.font_system.loadFont(path, 16);
    defer font.deinit();
    var selector = @FieldType(App, "font_selector"){ .small = font, .medium = font, .large = font };
    selector.initDerivedCache(allocator);
    defer selector.deinitDerivedCache();
    const sample = "AV ffi Windows";
    const baseline = try app.cx.text.shapeText(.{ .text = sample, .font_family = "system", .font_size = 16 });
    const original_width = baseline.total_advance;
    app.setFontSelector(&selector);
    defer app.resetFontSelector();
    const expected = font.measureWidth(sample);
    const shaped = try app.cx.text.shapeText(.{ .text = sample, .font_family = "system", .font_size = 16 });
    const visual = try app.cx.text.visualLine(.{ .text = sample, .font_family = "system", .font_size = 16 });
    const native = zenit_d3d11_contract_font_width(app.painter.native, font.native, sample.ptr, sample.len, 16);
    try require(@abs(original_width - expected) > 1);
    try require(@abs(shaped.total_advance - expected) < 0.01 and @abs(visual.width - expected) < 0.01 and @abs(app.cx.text.measureTextWidth(sample, 16, 400, false) - expected) < 0.01 and @abs(native - expected) < 0.01);
    // Alternate face identities at identical text/size/weight: cache must not conflate them.
    for (0..4) |_| {
        const other = zenit_d3d11_contract_font_width(app.painter.native, app.fonts[0].native, sample.ptr, sample.len, 16);
        const again = zenit_d3d11_contract_font_width(app.painter.native, font.native, sample.ptr, sample.len, 16);
        try require(@abs(other - native) > 1 and @abs(again - expected) < 0.01);
    }
    {
        const other = try App.init(std.heap.page_allocator, .{
            .io = app.cx.io,
        });
        defer other.deinit();
        _ = try fontWidth(other);
        try require(@abs(app.cx.text.measureTextWidth(sample, 16, 400, false) - expected) < 0.01);
    }
    var previous_clear: [4]f32 = undefined;
    zenit_d3d11_contract_clear_color(app.painter.native, &previous_clear);
    zenit_d3d11_probe_set_clear_color(app.painter.native, 1, 1, 1, 1);
    defer zenit_d3d11_probe_set_clear_color(app.painter.native, previous_clear[0], previous_clear[1], previous_clear[2], previous_clear[3]);
    const bitmap = try std.fmt.allocPrintSentinel(allocator, "{s}\\zenit-font-pixels-{x}.bmp", .{ temp, randomId(app.cx.io) }, 0);
    defer allocator.free(bitmap);
    defer std.Io.Dir.cwd().deleteFile(app.cx.io, bitmap) catch {};
    const private_hash = try renderFontHash(app, font.native, sample, bitmap);
    const system_hash = try renderFontHash(app, null, sample, bitmap);
    try require(private_hash != system_hash);
    try require(try renderFontHash(app, font.native, sample, bitmap) == private_hash);
    // Pending commands and layout entries own their COM refs even after the source Font dies.
    const transient = try app.font_system.loadFont(path, 16);
    const transient_hash = try renderFontHash(app, transient.native, sample, bitmap);
    transient.deinit();
    externRenderAgain(app) catch return error.AppFontConfigContractFailed;
    try require(try captureFontHash(app, bitmap) == transient_hash);
    {
        const window = try App.init(std.heap.page_allocator, .{
            .io = app.cx.io,
        });
        defer window.deinit();
        window.setFontSelector(&selector);
        try window.mount(mountFontFixture);
        std.log.info("external fixture mounted", .{});
        try window.painter.update(window.cx, &window.win);
        std.log.info("external fixture painter updated", .{});
        const drawn_font = zenit_d3d11_contract_last_text_font(window.painter.native) orelse return error.AppFontConfigContractFailed;
        std.log.info("external fixture identities drawn={x} expected={x}", .{ zenit_dwrite_font_identity(drawn_font), zenit_dwrite_font_identity(font.native) });
        try require(zenit_dwrite_font_identity(drawn_font) == zenit_dwrite_font_identity(font.native));
        _ = try captureFontHash(window, bitmap);
    }
    std.log.info("Windows external selector contract: private face, shaping, caret, native layout and cache identity PASS", .{});
}

extern fn zenit_d3d11_probe_render(*anyopaque) c_int;
fn externRenderAgain(app: *App) !void {
    try require(zenit_d3d11_probe_render(app.painter.native) != 0);
}
fn renderFontHash(app: *App, font: ?*anyopaque, sample: []const u8, path: [:0]const u8) !u64 {
    try require(zenit_d3d11_contract_render_font(app.painter.native, font, sample.ptr, @intCast(sample.len)) != 0);
    return captureFontHash(app, path);
}
fn captureFontHash(app: *App, path: [:0]const u8) !u64 {
    try require(try app.painter.captureBmp(path));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.cx.io, path, app.allocator, .limited(32 * 1024 * 1024));
    defer app.allocator.free(bytes);
    try require(bytes.len > 54 and std.mem.eql(u8, bytes[0..2], "BM"));
    const offset = std.mem.readInt(u32, bytes[10..14], .little);
    try require(offset < bytes.len);
    var ink: usize = 0;
    var i: usize = offset;
    while (i + 3 < bytes.len) : (i += 4) {
        if (bytes[i] < 180 and bytes[i + 1] < 180 and bytes[i + 2] < 180) ink += 1;
    }
    std.log.info("font fixture ink={d}", .{ink});
    try require(ink > 100 and ink < 10000);
    return std.hash.Wyhash.hash(0, bytes[offset..]);
}

fn mountFontFixture(cx: *ui.Cx, _: *ui.Scope) !*ui.Node {
    return ui.text(cx, "AV ffi Windows", .{ .font_size = 32, .font_weight = 400, .color = ui.Color.rgb(0, 0, 0) });
}

var registry_fixture_family: u16 = 0;
fn mountRegistryFixture(cx: *ui.Cx, _: *ui.Scope) !*ui.Node {
    return ui.text(cx, "AV ffi Windows", .{ .font_size = 32, .font_weight = 700, .font_family = registry_fixture_family, .color = ui.Color.rgb(0, 0, 0) });
}

fn registryFonts(io: std.Io) !void {
    const allocator = std.heap.page_allocator;
    const before = Window.liveWindowCount();
    const foreground = GetForegroundWindow();
    var registry = render.FontRegistry.init(allocator);
    defer registry.deinit();
    const first = try App.init(allocator, .{
        .io = io,
    });
    defer first.deinit();
    registry.setFontSystem(&first.font_system);
    const courier = try registry.intern("Courier New");
    const arial = try registry.intern("Arial");
    const missing = try registry.intern("__Zenit_missing_registry_face__");
    first.setFontRegistry(&registry);
    try require(registry.scale_factor == first.scale);
    const sample = "iiiiWWWW AV ffi Windows";
    const width_a = try registryWidth(first, &registry, courier, sample, 700, false);
    const width_b = try registryWidth(first, &registry, arial, sample, 700, true);
    try require(@abs(width_a - width_b) > 1);
    try require(@abs(try registryWidth(first, &registry, courier, sample, 700, false) - width_a) < 0.01);
    const missing_run = try first.cx.text.shapeText(.{ .text = sample, .font_family = "system", .font_family_id = @backingInt(missing), .font_size = 32 });
    const default_run = try first.cx.text.shapeText(.{ .text = sample, .font_family = "system", .font_size = 32 });
    try require(@abs(missing_run.total_advance - default_run.total_advance) < 0.01);
    {
        var other_registry = render.FontRegistry.init(allocator);
        defer other_registry.deinit();
        const other = try App.init(allocator, .{
            .io = io,
        });
        defer other.deinit();
        other_registry.setFontSystem(&other.font_system);
        const other_id = try other_registry.intern("Arial");
        try require(@backingInt(other_id) == @backingInt(courier));
        other.setFontRegistry(&other_registry);
        _ = try registryWidth(other, &other_registry, other_id, sample, 700, false);
        other.cx.text.syncLegacyMeasureHooks();
        try require(@abs(try registryWidth(first, &registry, courier, sample, 700, false) - width_a) < 0.01);
    }
    {
        const plain = try App.init(allocator, .{ .io = io, .font = .{ .fallback_families = &.{"Courier New"} } });
        defer plain.deinit();
        first.cx.text.syncLegacyMeasureHooks();
        const fresh = "isolated default WWiiii";
        const expected_font = try plain.font_system.findFont(.{ .family = "system", .size = 32 });
        defer expected_font.deinit();
        const fresh_run = try plain.cx.text.shapeText(.{ .text = fresh, .font_family = "system", .font_size = 32 });
        try require(@abs(fresh_run.total_advance - expected_font.measureWidth(fresh)) < 0.01);
    }
    first.cx.text.syncLegacyMeasureHooks();
    registry_fixture_family = @backingInt(courier);
    try first.mount(mountRegistryFixture);
    try first.painter.update(first.cx, &first.win);
    const drawn = zenit_d3d11_contract_last_text_font(first.painter.native) orelse return error.AppFontConfigContractFailed;
    try require(zenit_dwrite_font_identity(drawn) == zenit_dwrite_font_identity(registry.resolve(courier, 32, 700, false).?.native));
    const temp = try @import("zenit_environment").getOwned(allocator, "TEMP");
    defer allocator.free(temp);
    const bitmap = try std.fmt.allocPrintSentinel(allocator, "{s}\\zenit-registry-{x}.bmp", .{ temp, randomId(io) }, 0);
    defer allocator.free(bitmap);
    defer std.Io.Dir.cwd().deleteFile(io, bitmap) catch {};
    _ = try captureFontHash(first, bitmap);
    try require(GetForegroundWindow() == foreground and Window.liveWindowCount() == before + 1);
    std.log.info("Windows registry contract: family ids, bold/italic, cache isolation, visual caret and actual paint PASS", .{});
}

fn registryWidth(app: *App, registry: *render.FontRegistry, id: render.FamilyId, sample: []const u8, weight: u16, italic: bool) !f32 {
    const font = registry.resolve(id, 32, weight, italic) orelse return error.AppFontConfigContractFailed;
    const expected = font.measureWidth(sample);
    const options = ui.Cx.ShapeTextOpts{ .text = sample, .font_family = "system", .font_family_id = @backingInt(id), .font_size = 32, .font_weight = weight, .use_italic = italic };
    const run = try app.cx.text.shapeText(options);
    const line = try app.cx.text.visualLine(options);
    const width = zenit_d3d11_contract_font_width(app.painter.native, font.native, sample.ptr, @intCast(sample.len), 32);
    try require(expected > 0 and @abs(run.total_advance - expected) < 0.01 and @abs(line.width - expected) < 0.01 and @abs(width - expected) < 0.01);
    try require(font.scale_factor == app.scale and font.italic == italic);
    try require(line.xToPosition(.{ .value = expected }).byte.value == sample.len);
    const start = try line.positionToCaret(.{ .byte = .{ .value = 0 }, .affinity = .downstream });
    const end = try line.positionToCaret(.{ .byte = .{ .value = @intCast(sample.len) }, .affinity = .downstream });
    try require(@abs(start.x.value) < 0.01 and @abs(end.x.value - expected) < 0.01);
    std.log.info("registry family={s} weight={d} italic={} width={d:.2}", .{ font.family, weight, italic, expected });
    return expected;
}

fn randomId(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}
