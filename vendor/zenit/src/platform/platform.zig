const builtin = @import("builtin");

pub const Backend = switch (builtin.target.os.tag) {
    .macos => @import("macos/window.zig"),
    .windows => @import("windows/window.zig"),
    .linux => @import("linux/window.zig"),
    else => @import("unsupported/window.zig"),
};

pub const Window = switch (builtin.target.os.tag) {
    .macos => Backend.MacOSWindow,
    .windows => Backend.WindowsWindow,
    .linux => Backend.LinuxWindow,
    else => Backend.UnsupportedWindow,
};

pub const owned_window = @import("owned_window.zig");

// Re-export common types
pub const KeyEvent = Window.KeyEvent;
pub const Modifiers = Window.Modifiers;
pub const MouseButton = Window.MouseButton;
pub const KeyCode = Window.KeyCode;
pub const MenuAction = Window.MenuAction;
