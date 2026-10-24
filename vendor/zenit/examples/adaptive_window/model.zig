const app = @import("zenit_app");
const chrome = app.window_chrome;
pub const Preset = struct { id: []const u8, label: [:0]const u8, note: []const u8, appearance: chrome.Appearance, layout: chrome.ButtonLayout = .{}, native: bool = false, maximized: bool = false, radius: f32 = 8 };
pub const presets = [_]Preset{
    .{ .id = "macos", .label = "macOS", .note = "系统红绿灯 · 左置 · 应用菜单在系统菜单栏", .appearance = .macos, .radius = 12 },
    .{ .id = "windows", .label = "Windows 11", .note = "3 × 46 × 38 · DWM 边框与圆角", .appearance = .windows },
    .{ .id = "windows-max", .label = "Windows 11 · 最大化", .note = "圆角 0 · 还原字形 · 关闭命中屏幕右上角", .appearance = .windows, .maximized = true, .radius = 0 },
    .{ .id = "gnome", .label = "Linux · GNOME", .note = "appmenu:close · Adwaita 24px 圆钮", .appearance = .adwaita, .layout = chrome.ButtonLayout.parse("appmenu:close").?, .radius = 12 },
    .{ .id = "ubuntu", .label = "Linux · Ubuntu", .note = ":minimize,maximize,close", .appearance = .adwaita, .radius = 12 },
    .{ .id = "kde", .label = "Linux · KDE Plasma", .note = "Breeze 18px · 还原菱形 · 关闭悬停红圆", .appearance = .breeze, .radius = 6 },
    .{ .id = "left", .label = "Linux · 左置按钮", .note = "close,minimize,maximize: · 菜单紧随 Caption", .appearance = .adwaita, .layout = chrome.ButtonLayout.parse("close,minimize,maximize:").?, .radius = 12 },
    .{ .id = "fallback", .label = "回退 · 系统标题栏", .note = "SSD / 用户偏好 / 高对比度 · 内容保留为工具栏", .appearance = .adwaita, .native = true, .radius = 0 },
};
/// A preset can only be opened as a real window on the desktop it describes;
/// the native-titlebar fallback exists on every desktop.
pub fn fits(p: Preset) bool {
    if (p.native) return true;
    return switch (p.appearance) {
        .macos => app.build_environment.os == .macos,
        .windows => app.build_environment.os == .windows,
        .adwaita, .breeze => app.build_environment.os == .linux,
        .generic => true,
    };
}
pub fn fitsNote(p: Preset) []const u8 {
    if (p.native) return "";
    return switch (p.appearance) {
        .macos => "仅 macOS",
        .windows => "仅 Windows",
        .adwaita, .breeze => "仅 Linux",
        .generic => "",
    };
}
pub fn state(p: Preset, width: f32) chrome.State {
    return .{ .requested_mode = .custom, .effective_mode = if (p.native) .native else .custom, .controls_owner = if (p.native) .native else .application, .appearance = p.appearance, .button_layout = p.layout, .capabilities = .{ .custom = true, .frameless = true, .minimize = true, .maximize = true, .fullscreen = true, .interactive_move = true, .interactive_resize = true }, .maximized = p.maximized, .active = true, .width = width, .height = 600 };
}
pub fn captionWidth(layout: chrome.ButtonLayout, appearance: chrome.Appearance) f32 {
    var result: f32 = 0;
    for ([_][3]chrome.Control{ layout.left, layout.right }) |side| {
        var n: usize = 0;
        for (side) |c| {
            if (c != .none) n += 1;
        }
        if (n > 0) result += if (appearance == .windows) @as(f32, @floatFromInt(n)) * 46 else (if (appearance == .breeze) @as(f32, 20) else @as(f32, 16)) + @as(f32, @floatFromInt(n)) * (if (appearance == .breeze) @as(f32, 18) else @as(f32, 24)) + @as(f32, @floatFromInt(n - 1)) * (if (appearance == .breeze) @as(f32, 8) else @as(f32, 12));
    }
    return result;
}
