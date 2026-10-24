//! Native Win32 bootstrap probe. The GDI fallback in the window bridge paints
//! a swatch and text so the VM can prove a real pixel-producing window exists.
//! This is not Zenit's production GPU renderer.
const platform = @import("platform");
const system_sdk = @import("system_sdk");
const std = @import("std");

extern fn zenit_d3d11_probe_create(hwnd: *anyopaque) ?*anyopaque;
extern fn zenit_d3d11_probe_render(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_destroy(probe: *anyopaque) void;
extern fn zenit_d3d11_probe_driver(probe: *anyopaque) c_int;

fn renderD3D11(ctx: ?*anyopaque) callconv(.c) void {
    const probe = ctx orelse return;
    _ = zenit_d3d11_probe_render(probe);
}

pub fn main() !void {
    var window = try platform.Window.init(800, 600, "Zenit Windows ARM64");
    defer window.deinit();
    const gpu_probe = zenit_d3d11_probe_create(window.getNativeSurfaceHandle());
    defer if (gpu_probe) |probe| zenit_d3d11_probe_destroy(probe);
    if (gpu_probe) |probe| {
        window.setRenderCallback(renderD3D11, probe);
        window.requestRedraw();
        std.debug.print("D3D11 probe initialized ({s})\n", .{if (zenit_d3d11_probe_driver(probe) == 1) "hardware" else "WARP"});
    } else {
        std.debug.print("D3D11 unavailable; showing GDI diagnostic frame\n", .{});
    }
    var sdk = try system_sdk.backends.initSystemSdk(std.heap.page_allocator, &window, window.getWindowId());
    defer sdk.deinit();
    var input_bytes: [32]u8 = undefined;
    while (true) {
        platform.Window.pumpAppEventsTimeout(16);
        const result = try sdk.pump(0);
        if (!result.should_continue) break;
        _ = window.getKeyEvent();
        _ = window.getMouseButtonEvent();
        _ = window.getScrollDelta();
        _ = window.getInputText(&input_bytes);
    }
}
