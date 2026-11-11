//! Main-thread system panel boundary. Cancellation never selects an asset or
//! edits Config. All returned paths are copied before the native buffer dies.
const ui = @import("ui");
const Command = @import("appearance_ui_context.zig").Command;
const Worker = @import("appearance_ui_worker.zig").Worker;
const Controller = @import("settings_controller.zig").Controller;
const themes = @import("theme_registry.zig");
const FileSheet = @import("../platform/file_sheet.zig").Sheet;

/// Returns false for commands handled by SettingsHost (font validation,
/// material preview/restore, and ordinary draft changes).
pub fn dispatch(cx: *ui.Cx, worker: *Worker, controller: *Controller, registry: *themes.Registry, saved_theme: []const u8, command: Command) !bool {
    switch (command) {
        .pick_theme => |request| {
            if (worker.busy()) {
                controller.cancelThemeImport(request);
                return error.AppearanceBusy;
            }
            const active = controller.theme_library.import_operation orelse return error.StaleThemeImport;
            if (active.draft_id != request.draft_id or active.operation_id != request.operation_id) return error.StaleThemeImport;
            const sheet = FileSheet.begin(cx, .{ .kind = .file, .title = "导入 .itermcolors 主题" }) catch |err| {
                _ = controller.failThemeImport(request, err);
                return err;
            };
            worker.picker = .{ .sheet = sheet, .request = .{ .theme = request } };
            return true;
        },
        .pick_background => |request| {
            if (worker.busy()) return error.AppearanceBusy;
            if (controller.draft_id != request.draft_id or controller.background.asset_revision != request.asset_revision) return error.StaleBackgroundRequest;
            const sheet = try FileSheet.begin(cx, .{ .kind = .file_or_folder, .title = "选择背景图片或目录", .prompt = "选择", .message = "选择一张图片，或选择一个目录用于轮播。" });
            worker.picker = .{ .sheet = sheet, .request = .{ .background = request } };
            return true;
        },
        .favorite => |request| {
            try worker.startFavorite(registry, request.id, request.registry_revision, request.enabled);
            return true;
        },
        .remove_theme => |request| {
            try worker.startRemove(registry, request.id, request.registry_revision, .{ .saved = saved_theme, .draft = controller.model.value.ui.theme });
            return true;
        },
        else => return false,
    }
}
