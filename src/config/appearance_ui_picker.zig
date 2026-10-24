//! Main-thread system panel boundary. Cancellation never selects an asset or
//! edits Config. All returned paths are copied before the native buffer dies.
const ui = @import("ui");
const Command = @import("appearance_ui_context.zig").Command;
const Worker = @import("appearance_ui_worker.zig").Worker;
const Controller = @import("settings_controller.zig").Controller;
const themes = @import("theme_registry.zig");

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
            var buffer: [4096]u8 = undefined;
            const path = choose(cx, worker, "导入 .itermcolors 主题", &buffer) catch |err| {
                _ = controller.failThemeImport(request, err);
                return err;
            } orelse {
                controller.cancelThemeImport(request);
                return true;
            };
            const current = controller.theme_library.import_operation orelse return error.StaleThemeImport;
            if (current.draft_id != request.draft_id or current.operation_id != request.operation_id) return error.StaleThemeImport;
            worker.startThemeImport(request, path) catch |err| {
                _ = controller.failThemeImport(request, err);
                return err;
            };
            return true;
        },
        .pick_background => |request| {
            if (worker.busy()) return error.AppearanceBusy;
            if (controller.draft_id != request.draft_id or controller.background.asset_revision != request.asset_revision) return error.StaleBackgroundRequest;
            var buffer: [4096]u8 = undefined;
            const path = try choose(cx, worker, "选择背景图片", &buffer) orelse return true;
            if (controller.draft_id != request.draft_id or controller.background.asset_revision != request.asset_revision) return error.StaleBackgroundRequest;
            var owned = try controller.requestBackground(path);
            worker.startBackground(&owned) catch |err| {
                _ = controller.failBackground(owned.request, err);
                owned.deinit();
                return err;
            };
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

fn choose(cx: *ui.Cx, worker: *Worker, title: []const u8, buffer: []u8) !?[]const u8 {
    const sdk = cx.system_sdk orelse return error.NotSupported;
    worker.picker_active = true;
    defer worker.picker_active = false;
    // The current SDK has no content-type filter. The worker validates the
    // actual selected format; this is a real system open-file panel.
    return sdk.runDialog(.{ .kind = .open_file, .title = title }, buffer);
}
