//! Settings-owned appearance boundary. Commands are captured on the UI thread;
//! the host copies their inputs and publishes worker results at its safe hook.
const ui = @import("ui");
const themes = @import("theme_registry.zig");
const runtime = @import("runtime_config.zig");

pub const Command = union(enum) {
    pick_theme: themes.ImportRequest,
    pick_background: struct { draft_id: u64, asset_revision: u64 },
    favorite: struct { id: []const u8, registry_revision: u64, enabled: bool },
    remove_theme: struct { id: []const u8, registry_revision: u64 },
    preview_material: bool,
    restore_materials,
    validate_font,
    draft_values_changed,
};
pub const FontStatus = struct {
    actual_family: []const u8 = "",
    fallback: bool = false,
    problem: ?[]const u8 = null,
};
pub const Context = struct {
    registry: *themes.Registry,
    runtime: *runtime.RuntimeConfig,
    context: *anyopaque,
    /// Command string slices are valid only during the callback.
    request: *const fn (*anyopaque, Command) void,
    busy: ?*const fn (*anyopaque) bool = null,
    font_status: ?*const fn (*anyopaque) FontStatus = null,
    preview_active: bool = false,
    library_dismissed: bool = false,
    custom_font_edit: bool = false,
    focus_custom_font: bool = false,
    selected_image_path: []const u8 = "",
    /// The native renderer may mount the prepared background thumbnail. The
    /// view does not read a file or allocate a GPU texture itself.
    mount_image: ?*const fn (*anyopaque, *ui.Cx, *ui.Scope, f32, f32) anyerror!*ui.Node = null,

    pub fn isBusy(self: Context) bool {
        return if (self.busy) |read| read(self.context) else false;
    }
    pub fn send(self: Context, command: Command) void {
        self.request(self.context, command);
    }
};
