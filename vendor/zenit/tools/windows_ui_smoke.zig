//! Native Win32 bootstrap probe. The GDI fallback in the window bridge paints
//! a swatch and text so the VM can prove a real pixel-producing window exists.
//! This is not Zenit's production GPU renderer.
const platform = @import("platform");
const system_sdk = @import("system_sdk");
const std = @import("std");
const ui = @import("ui");
const text = @import("text");

extern fn zenit_d3d11_probe_create(hwnd: *anyopaque) ?*anyopaque;
extern fn zenit_d3d11_probe_render(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_destroy(probe: *anyopaque) void;
extern fn zenit_d3d11_probe_driver(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_items_supported(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_item_size() usize;
const PaintItem = @FieldType(@import("zenit_app").App, "painter").NativePaintItem;
extern fn zenit_d3d11_probe_set_items(probe: *anyopaque, items: [*]const PaintItem, count: u32, scale: f32) c_int;

fn renderD3D11(ctx: ?*anyopaque) callconv(.c) void {
    const probe = ctx orelse return;
    _ = zenit_d3d11_probe_render(probe);
}

pub fn main(init: std.process.Init) !void {
    if (zenit_d3d11_probe_item_size() != @sizeOf(PaintItem)) return error.PaintItemAbiMismatch;
    var window = try platform.Window.init(800, 600, "Zenit Windows ARM64");
    defer window.deinit();
    const gpu_probe = zenit_d3d11_probe_create(window.getNativeSurfaceHandle());
    defer if (gpu_probe) |probe| zenit_d3d11_probe_destroy(probe);
    if (gpu_probe) |probe| {
        if (zenit_d3d11_probe_items_supported(probe) == 0) return error.D2DRenderTargetUnavailable;
        window.setRenderCallback(renderD3D11, probe);
        window.requestRedraw();
        std.debug.print("D3D11 probe initialized ({s})\n", .{if (zenit_d3d11_probe_driver(probe) == 1) "hardware" else "WARP"});
    } else {
        std.debug.print("D3D11 unavailable; showing GDI diagnostic frame\n", .{});
    }
    var sdk = try system_sdk.backends.initSystemSdk(std.heap.page_allocator, &window, window.getWindowId());
    defer sdk.deinit();
    var font_system = try text.FontSystem.init(std.heap.page_allocator, init.io);
    defer font_system.deinit();
    const cx = try ui.Cx.init(std.heap.page_allocator, init.io);
    defer cx.deinit();
    cx.setWindowId(window.getWindowId());
    cx.setSystemSdk(&sdk);
    cx.text.setFontSystem(&font_system);
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    cx.root_scope = scope;
    var size = window.getSize();
    var scale = window.getScaleFactor();
    cx.setWindowMetrics(@floatFromInt(size[0]), @floatFromInt(size[1]), scale);
    const swatch = try ui.box(cx, .{ .width = .{ .px = 220 }, .height = .{ .px = 120 }, .background = ui.Color.hex(0x368CEB) }, .{});
    const label = try ui.text(cx, "Zenit Windows ARM64", .{ .font_size = 24, .color = ui.Color.WHITE });
    const input = try ui.widgets.Input(.{ .label_text = "IME test", .placeholder = "Type Chinese or Japanese", .width = 360 }).mount(scope, cx);
    cx.root = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column, .gap = 16, .padding = ui.Padding.all(40), .background = ui.Color.hex(0x172D4D) }, .{ swatch, label, input });
    try updatePaint(cx, &window, gpu_probe);
    var swatch_pressed = false;
    var swatch_active = false;
    while (true) {
        platform.Window.pumpAppEventsTimeout(16);
        const result = try sdk.pump(0);
        if (!result.should_continue) break;
        for (sdk.events()) |event| {
            switch (event) {
                .window_focused => |e| if (!e.focused) {
                    cx.cancelPointerInteractions(.window_blur);
                    swatch_pressed = false;
                },
                .mouse_move => |e| cx.handleMouseMoveEx(e.x, e.y, uiModifiers(e.modifiers)),
                .mouse_button => |e| {
                    const button: ui.events.MouseButton = switch (e.button) {
                        .left => .left,
                        .right => .right,
                        .middle => .middle,
                        .other => continue,
                    };
                    if (e.pressed) {
                        cx.handleMouseDownEx(e.x, e.y, button, uiModifiers(e.modifiers));
                        if (button == .left) swatch_pressed = insideNode(swatch, e.x, e.y);
                    } else {
                        cx.handleMouseUpEx(e.x, e.y, button, uiModifiers(e.modifiers));
                        if (button == .left) {
                            if (swatch_pressed and insideNode(swatch, e.x, e.y)) {
                                swatch_active = !swatch_active;
                                swatch.setBackground(ui.Color.hex(if (swatch_active) 0xF5A623 else 0x368CEB));
                            }
                            swatch_pressed = false;
                        }
                    }
                },
                .mouse_wheel => |e| cx.handleSdkWheel(e),
                .key => |e| {
                    const key = ui.events.KeyCode.fromWindowsVirtualKey(e.keycode);
                    if (e.pressed) cx.handleKeyDown(key, uiModifiers(e.modifiers)) else cx.handleKeyUp(key, uiModifiers(e.modifiers));
                },
                .text_input => |e| cx.handleTextInput(e.text),
                .ime_preedit => |e| cx.handleImePreeditReplace(e.text, e.cursor_utf8_offset, e.replace_start_utf8, e.replace_end_utf8),
                .ime_commit => |e| cx.handleImeCommitReplace(e.text, e.replace_start_utf8, e.replace_end_utf8),
                else => {},
            }
        }
        const current_size = window.getSize();
        const current_scale = window.getScaleFactor();
        if (current_size[0] != size[0] or current_size[1] != size[1] or current_scale != scale) {
            size = current_size;
            scale = current_scale;
            cx.setWindowMetrics(@floatFromInt(size[0]), @floatFromInt(size[1]), scale);
            try updatePaint(cx, &window, gpu_probe);
        }
        if (cx.needs_redraw) try updatePaint(cx, &window, gpu_probe);
    }
}

fn insideNode(node: *ui.Node, x: f32, y: f32) bool {
    const rect = node.rectFromWorldOrFallback();
    return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
}

fn uiModifiers(mods: system_sdk.events.Modifiers) ui.events.Modifiers {
    return .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .super = mods.super };
}

fn updatePaint(cx: *ui.Cx, window: *platform.Window, gpu_probe: ?*anyopaque) !void {
    _ = cx.render();
    const paint = cx.lowerForEncoderPaintTable();
    var items: std.ArrayList(PaintItem) = .empty;
    defer items.deinit(std.heap.page_allocator);
    for (paint) |item| {
        if (item.kind == .rect and item.stroke_width == 0 and item.noise_intensity == 0) {
            try items.append(std.heap.page_allocator, .{
                .kind = 1,
                .x = item.geom.x,
                .y = item.geom.y,
                .w = item.geom.w,
                .h = item.geom.h,
                .r = @as(f32, @floatFromInt(item.color.r)) / 255,
                .g = @as(f32, @floatFromInt(item.color.g)) / 255,
                .b = @as(f32, @floatFromInt(item.color.b)) / 255,
                .a = @as(f32, @floatFromInt(item.color.a)) / 255,
                .radius = @min(item.radii.tl, @min(item.radii.tr, @min(item.radii.br, item.radii.bl))),
                .font_size = 0,
                .font_weight = 0,
                .text = null,
                .text_length = 0,
                .to_r = 0,
                .to_g = 0,
                .to_b = 0,
                .to_a = 0,
                .gradient_direction = 0,
                .stroke_width = 0,
            });
        } else if (item.kind == .text and item.text_content.len > 0 and item.text_content.len <= std.math.maxInt(u32)) {
            try items.append(std.heap.page_allocator, .{
                .kind = 2,
                .x = item.geom.x,
                .y = item.geom.y,
                .w = 0,
                .h = 0,
                .r = @as(f32, @floatFromInt(item.color.r)) / 255,
                .g = @as(f32, @floatFromInt(item.color.g)) / 255,
                .b = @as(f32, @floatFromInt(item.color.b)) / 255,
                .a = @as(f32, @floatFromInt(item.color.a)) / 255,
                .radius = 0,
                .font_size = item.text_font_size,
                .font_weight = item.text_font_weight,
                .text = item.text_content.ptr,
                .text_length = @intCast(item.text_content.len),
                .to_r = 0,
                .to_g = 0,
                .to_b = 0,
                .to_a = 0,
                .gradient_direction = 0,
                .stroke_width = 0,
            });
        } else if (item.kind == .control) {
            switch (item.control_kind) {
                .push_clip => try items.append(std.heap.page_allocator, clipItem(switch (item.clip_shape_kind) {
                    1 => 9, // rounded rectangle
                    2 => 10, // ellipse
                    else => 3, // rectangular or unsupported shape fallback
                }, item.geom, item.radii.tl)),
                .pop_clip => try items.append(std.heap.page_allocator, clipItem(4, item.geom, 0)),
                else => {},
            }
        }
    }
    if (gpu_probe) |probe| {
        if (zenit_d3d11_probe_set_items(probe, items.items.ptr, @intCast(items.items.len), window.getScaleFactor()) == 0)
            return error.PaintUploadFailed;
        window.requestRedraw();
    }
    std.debug.print("Zenit UI generated {d} paint items, {d} native draw/clip commands\n", .{ paint.len, items.items.len });
}

fn clipItem(kind: u32, geom: anytype, radius: f32) PaintItem {
    return .{
        .kind = kind,
        .x = geom.x,
        .y = geom.y,
        .w = geom.w,
        .h = geom.h,
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 0,
        .radius = radius,
        .font_size = 0,
        .font_weight = 0,
        .text = null,
        .text_length = 0,
        .to_r = 0,
        .to_g = 0,
        .to_b = 0,
        .to_a = 0,
        .gradient_direction = 0,
        .stroke_width = 0,
    };
}
