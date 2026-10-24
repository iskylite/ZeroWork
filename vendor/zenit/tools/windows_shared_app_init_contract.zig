//! Shared Direct3D App initialization and font contracts. Legacy D3D11 layout
//! counters belong to the legacy fixture; shared rendering is checked in pixels.
const std = @import("std");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
const Storage = @import("windows_app_init_contract.zig").ReusedAllocator;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern fn zenit_windows_contract_background(c_int) c_int;

fn require(ok: bool) !void {
    if (!ok) return error.SharedAppInitContractFailed;
}
fn width(app: *App) !f32 {
    const sample = "iiiiWWWW font configuration";
    const size = app.fonts[0].pixelSize();
    const expected = app.fonts[0].measureWidth(sample);
    const run = try app.cx.text.shapeText(.{ .text = sample, .font_family = "system", .font_size = size });
    const line = try app.cx.text.visualLine(.{ .text = sample, .font_family = "system", .font_size = size });
    try require(expected > 0 and @abs(run.total_advance - expected) < 0.01 and @abs(line.width - expected) < 0.01);
    return expected;
}
pub const ReusedAllocator = struct {
    storage: Storage = .{},
    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.storage.allocator();
    }
    pub fn beforeReuse(self: *@This(), io: std.Io) !void {
        const background = zenit_windows_contract_background(1);
        defer _ = zenit_windows_contract_background(background);
        try @import("windows_window_contract.zig").runInitialGeometry();
        const before = Window.liveWindowCount();
        const foreground = GetForegroundWindow();
        if (App.init(self.allocator(), .{ .io = io, .font = .{ .small_size = 0 } })) |unexpected| {
            unexpected.deinit();
            return error.AcceptedInvalidFontSize;
        } else |err| try require(err == error.InvalidFontSize);
        try require(!self.storage.in_use and Window.liveWindowCount() == before);
        {
            var family = [_]u8{ 'C', 'o', 'u', 'r', 'i', 'e', 'r', ' ', 'N', 'e', 'w' };
            const previous = try App.init(self.allocator(), .{ .io = io, .font = .{ .fallback_families = &.{&family} } });
            defer previous.deinit();
            @memset(&family, 'x');
            try require(std.mem.eql(u8, previous.resolved_font_family, "Courier New"));
            const courier = try width(previous);
            {
                const other = try App.init(std.heap.page_allocator, .{ .io = io, .font = .{ .fallback_families = &.{"Arial"} } });
                defer other.deinit();
                try require(@abs(try width(other) - courier) > 1);
                try require(@abs(try width(previous) - courier) < 0.01);
            }
            {
                const fallback = try App.init(std.heap.page_allocator, .{ .io = io, .font = .{ .fallback_families = &.{"__Zenit_missing_font__"} } });
                defer fallback.deinit();
                _ = try width(fallback);
                try require(std.mem.eql(u8, fallback.resolved_font_family, "system"));
            }
            previous.quit();
            try require(previous.should_quit);
        }
        try require(!self.storage.in_use and Window.liveWindowCount() == before and GetForegroundWindow() == foreground);
    }
    pub fn afterReuse(self: *@This(), app: *App) !void {
        try require(self.storage.app_allocations == 2 and @intFromPtr(app) == @intFromPtr(&self.storage.storage));
        const bytes: [*]const volatile u8 = @ptrCast(app);
        inline for (.{ "should_quit", "native_frame_active", "native_redraw_pending", "in_native_callback" }) |field| {
            try require(bytes[@offsetOf(App, field)] == 0);
        }
        _ = try width(app);
        try @import("windows_font_paint_contract.zig").run(app.cx.io);
        std.log.info("Shared Direct3D App init contract: nonzero allocation, quit/reuse, owned family, missing fallback, window isolation, shaping and actual font-range paint PASS", .{});
        std.log.info("Private layout/device counters are legacy-only; this shared fixture verifies rendered pixels", .{});
    }
};
