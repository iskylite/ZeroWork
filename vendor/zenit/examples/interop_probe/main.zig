/// interop_probe: real-hardware verification probe for rich clipboard + file drag-out
/// (script-driven, not a product demo).
///
/// Unlike e2e injection, this verifies real system paths:
///   - On startup, read system clipboard HTML (preset by an external script) -> verifies the get
///     path;
///   - Then write text+HTML rich clipboard -> external script reads it back to verify the set path;
///   - Mouse down anywhere in the window -> beginDrag(file_url) starts a real AppKit drag session
///     -> scripts/verify_interop_probe.sh uses CGEvent to drag to Finder; pass = file appears in
///     target dir.
///
/// All criteria go through stdout `[PROBE]` lines + external system state, which the script greps.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

var g_app: *App = undefined;
var g_drag_started: bool = false;

fn onProbeEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
    _ = context;
    switch (event) {
        .mouse_down => |e| {
            // Only window's left half is drag source; right half for normal clicks
            // (focus/activate), else verify_menu.sh's focus click spawns an empty drag session
            // eating all following keyboard events (confirmed: Cmd+P never reaches the event loop).
            if (e.x >= 200) return .ignored;
            // Must start drag immediately in mousedown (AppKit requires the current event is the
            // drag source event; see scripts/verify_real_drag.sh for tested experience).
            if (g_drag_started) return .ignored;
            g_drag_started = true;
            const token = g_app.sdk.beginDrag(g_app.windowId(), .{
                .payload_kind = .file_url,
                .payload = "/tmp/zenit-dragout/payload.txt",
                .allowed_operations = .{ .copy = true },
            }) catch |err| {
                std.debug.print("[PROBE] beginDrag failed: {}\n", .{err});
                return .ignored;
            };
            std.debug.print("[PROBE] beginDrag ok token={d}\n", .{token});
            return .handled;
        },
        else => {},
    }
    return .ignored;
}

fn onProbeAction(action: ui.actions.Action, context: ?*anyopaque) ui.events.EventResult {
    _ = context;
    std.debug.print("[PROBE] action {s}\n", .{action.name});
    return .handled;
}

const v = ui.view;

fn rootStyle(t: *const ui.theme.Values) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .background = t.tokens.color.bg_primary };
}

/// Probe needs raw event flow and native menu routing, node-level capability below DSL: connected
/// via `v.setup`.
fn wireProbe(_: void, root: *ui.Node, _: *ui.Scope, cx: *ui.Cx) void {
    root.behavior.events.on_event = onProbeEvent;
    root.behavior.events.event_context = root; // non-null ok, handler doesn't use it.
    // Native menu acceptance: menu_command -> ActionDispatcher -> this handler prints.
    root.behavior.interaction.key_context = "probe";
    root.behavior.events.on_action = onProbeAction;
    cx.bindCommandAction(100, .{ .context = "probe", .name = "ping" });
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return v.render(scope, cx, v.setup(v.box(.{ .style = rootStyle }, .{}), {}, wireProbe));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try App.init(allocator, .{
        .io = init.io,
        .window = .{ .width = 400, .height = 300, .title = "zenit interop probe" },
    });
    defer app.deinit();
    g_app = app;

    // ---- Clipboard get path: read HTML preset by external script ----
    if (app.sdk.clipboardGetHtmlAlloc(allocator) catch null) |html| {
        defer allocator.free(html);
        std.debug.print("[PROBE] read-html: {s}\n", .{html});
    } else {
        std.debug.print("[PROBE] read-html: <none>\n", .{});
    }

    // ---- Clipboard set path: write text+HTML dual representation ----
    if (app.sdk.clipboardSetRichText(.{
        .text = "zenit-probe-plain",
        .html = "<b>zenit-probe-html</b>",
    })) |_| {
        std.debug.print("[PROBE] rich-set-ok\n", .{});
    } else |e| {
        std.debug.print("[PROBE] rich-set failed: {}\n", .{e});
    }

    // ---- Native menu: real AppKit menu bar click / Cmd+P hotkey acceptance target ----
    // Note: AppKit renders the first top-level menu item as the app menu (forces rename to app
    // name), so a placeholder app menu must precede custom menus or the first menu is swallowed.
    app.setMenuModel(.{ .nodes = &.{
        .{ .id = 1, .kind = .menu, .label = "App" },
        .{ .id = 2, .kind = .menu, .label = "Probe" },
        .{ .id = 3, .parent_id = 2, .kind = .item, .label = "Ping", .key_equivalent = "p", .modifiers = .{ .super = true }, .command_id = 100 },
    } }) catch |e| std.debug.print("[PROBE] menu-set failed: {}\n", .{e});

    try app.runWith(mountUI);
}
