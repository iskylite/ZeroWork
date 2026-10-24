//! Real D3D11 interop through the public platform Window device handle.
const std = @import("std");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
const Painter = @FieldType(App, "painter");
extern fn zenit_d3d11_probe_device(*anyopaque) ?*anyopaque;
extern fn zenit_d3d11_contract_create_texture(*anyopaque) ?*anyopaque;
extern fn zenit_d3d11_contract_texture_device(*anyopaque, *anyopaque) c_int;
extern fn zenit_d3d11_contract_release_texture(*anyopaque) void;
fn require(ok: bool) !void {
    if (!ok) return error.NativeDeviceContractFailed;
}
pub fn run(app: *App) !void {
    const device = app.win.getNativeDeviceHandle();
    try require(zenit_d3d11_probe_device(app.painter.native) == device);
    const resource = zenit_d3d11_contract_create_texture(device) orelse return error.NativeDeviceTextureFailed;
    defer zenit_d3d11_contract_release_texture(resource);
    try require(zenit_d3d11_contract_texture_device(resource, device) == 1);
    const size = app.win.getSize();
    try require(app.win.setSizeChecked(size[0] + 17, size[1] + 11));
    try require(app.win.getNativeDeviceHandle() == device);
    try require(zenit_d3d11_contract_texture_device(resource, device) == 1);
    try require(app.win.setSizeChecked(size[0], size[1]));

    var window = try Window.init(160, 100, "Owned D3D11 device contract");
    defer window.deinit();
    try require(window.native_device == null);
    var painter = try Painter.init(std.heap.page_allocator, app.cx.io, &window, .{ 0, 0, 0, 1 });
    var painter_alive = true;
    defer if (painter_alive) painter.deinit(&window);
    const other = window.getNativeDeviceHandle();
    try require(other != device and zenit_d3d11_probe_device(painter.native) == other);
    const retained = zenit_d3d11_contract_create_texture(other) orelse return error.NativeDeviceTextureFailed;
    defer zenit_d3d11_contract_release_texture(retained);
    try require(zenit_d3d11_contract_texture_device(retained, other) == 1);
    painter.deinit(&window);
    painter_alive = false;
    try require(window.native_device == null);
    // Resource ownership, rather than a borrowed raw pointer, keeps COM alive.
    try require(zenit_d3d11_contract_texture_device(retained, other) == 1);
    try require(app.win.getNativeDeviceHandle() == device);
    try require(zenit_d3d11_contract_texture_device(resource, device) == 1);

    var replacement = try Painter.init(std.heap.page_allocator, app.cx.io, &window, .{ 0, 0, 0, 1 });
    defer replacement.deinit(&window);
    const rebound = window.getNativeDeviceHandle();
    try require(rebound != other and rebound != device);
    const fresh = zenit_d3d11_contract_create_texture(rebound) orelse return error.NativeDeviceTextureFailed;
    defer zenit_d3d11_contract_release_texture(fresh);
    try require(zenit_d3d11_contract_texture_device(fresh, rebound) == 1);
    try require(zenit_d3d11_contract_texture_device(retained, other) == 1);
}
