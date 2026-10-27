//! Production Popover material checks; no native window is started.
const std = @import("std");
const ui = @import("ui");
const controls = @import("ui/ai_composer_controls_view.zig");
const layers = @import("ui/background_layers.zig");
const theme = @import("ui/app_theme.zig");
const assets = @import("config/background_asset.zig");
const shell = @import("ui/shell_styles.zig");

fn frame(cx: *ui.Cx) []const ui.DisplayItem {
    for (0..20) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    return cx.render();
}
fn action(_: *anyopaque, _: controls.Envelope) !void {}
fn find(node: *ui.Node, id: u64) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
fn contains(rect: ui.ComputedRect, x: f32, y: f32) bool {
    return x > rect.x and y > rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
}

test "production AI permission popover reveals the single global material in the final paint stream" {
    const saved_parameters = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved_parameters.transparency, saved_parameters.blur);
    _ = theme.setMaterialParameters(75, 24);
    const old_name = theme.currentName();
    const old_material = theme.materialVisible();
    defer {
        theme.select(old_name);
        _ = theme.setMaterialVisible(old_material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    try cx.setTestFrameStep(16);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const source = try layers.View.mount(cx, scope);
    try cx.root.?.appendChild(a, source.root);
    const publication = try cx.bindState(shell.ThemePublication, .{});
    publication.publish(cx, theme.widgetTheme(.dark));
    const parent = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 100 } }, .width = .{ .px = 600 }, .height = .{ .px = 420 }, .background = theme.current().overlay }, .{});
    try cx.root.?.appendChild(a, parent);
    try source.isolate(scope, parent);
    var context: u8 = 0;
    const view = try controls.View.mount(cx, scope, .{ .context = &context, .action = action });
    view.root.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .top = .{ .px = 384 } }, .width = .{ .px = 572 } });
    try parent.appendChild(a, view.root);
    try view.update(.{ .owner = .{ .session = 1 }, .revision = 1 });
    for (view.popups) |popup| try source.isolate(popup.widget.scope, popup.widget.chrome);
    _ = frame(cx);
    _ = theme.setMaterialVisible(true);
    publication.publish(cx, theme.widgetTheme(.dark));
    parent.setBackground(theme.current().overlay);
    const material: assets.Materials = .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fill, .transparency = 35 } };
    try source.update(.{ .id = 777, .width = 2, .height = 2 }, material, 1440, 900);
    _ = frame(cx);
    cx.setFocus(view.buttons[1]);
    cx.handleKeyDown(.@"return", .{});
    const items = frame(cx);
    const popup = view.popups[1];
    try std.testing.expect(popup.widget.open.?.peek());
    for (popup.widget.chrome.children.items) |child| try std.testing.expect(!layers.isSurface(child));
    try std.testing.expectEqual(theme.current().overlay, popup.widget.chrome.getBackground());
    const rect = popup.widget.chrome.globalRect();
    var projected: usize = 0;
    var image_order: ?usize = null;
    var after_image_fills: usize = 0;
    var opaque_after_image: usize = 0;
    for (items, 0..) |item, index| switch (item) {
        .image_quad => |q| if (q.texture_id == 777) {
            projected += 1;
            image_order = index;
        },
        .fill_rect => |fill| if (image_order != null) {
            const node = find(cx.root.?, fill.header.node_id) orelse continue;
            if (!node.isDescendantOf(popup.widget.chrome)) continue;
            if (contains(node.globalRect(), rect.x + rect.w / 2, rect.y + rect.h / 2)) {
                after_image_fills += 1;
                if (fill.color.a == 255) opaque_after_image += 1;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), projected);
    try std.testing.expect(image_order != null);
    try std.testing.expectEqual(@as(usize, 0), opaque_after_image);
    try std.testing.expect(after_image_fills > 0);
}

test "production bottom More retains global material through row rebuild and reopen" {
    const old_name = theme.currentName();
    const old_material = theme.materialVisible();
    defer {
        theme.select(old_name);
        _ = theme.setMaterialVisible(old_material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(true);
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    try cx.setTestFrameStep(16);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const source = try layers.View.mount(cx, scope);
    try cx.root.?.appendChild(a, source.root);
    const trigger = try ui.widgets.Button(.{ .a11y_label = "更多终端状态" }).mount(scope, cx);
    trigger.setStyleInline(a, .{ .position = .absolute, .width = .{ .px = 26 }, .height = .{ .px = 26 }, .inset = .{ .right = .{ .px = 20 }, .bottom = .{ .px = 20 } } });
    try cx.root.?.appendChild(a, trigger);
    var context: u8 = 0;
    const view = try @import("ui/status_detail_view.zig").View.mount(cx, scope, .{ .context = &context });
    try cx.root.?.appendChild(a, view.root);
    try source.isolate(view.scope, view.chrome);
    try source.update(.{ .id = 777, .width = 2, .height = 2 }, .{ .background = .{ .enabled = true, .path = "/fixture", .fit = .fill, .transparency = 35 } }, 1440, 900);
    try view.update(.{ .owner = .{ .session = .{ .session_id = @fromBackingInt(1) } }, .owner_kind = .local, .source_revision = 1, .identity_label = "本地 · zsh", .encoding = .utf8, .grid = .{ .cols = 80, .rows = 24, .revision = 1 } });
    _ = frame(cx);
    for (view.chrome.children.items) |child| try std.testing.expect(!layers.isSurface(child));
    for (0..3) |_| {
        try view.show(.more, trigger, 860, false);
        const items = frame(cx);
        try std.testing.expect(view.open.peek());
        try std.testing.expectEqual(theme.current().overlay, view.chrome.getBackground());
        var images: usize = 0;
        var title = false;
        for (items) |item| switch (item) {
            .image_quad => |quad| if (quad.texture_id == 777) {
                images += 1;
            },
            .text_run => |run| if (std.mem.eql(u8, run.content, "更多状态")) {
                title = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), images);
        try std.testing.expect(title);
        view.hide();
        _ = frame(cx);
        try std.testing.expect(!view.open.peek());
    }
}

fn authSubmit(_: *anyopaque, _: @import("proto/ssh/auth_challenge.zig").RequestIdentity, _: @import("proto/ssh/auth_challenge.zig").Reply) !void {}
fn authCancel(_: *anyopaque, _: @import("proto/ssh/auth_challenge.zig").RequestIdentity) void {}

test "production auth content inherits modal and inline material across retheme without replacing secrets" {
    const previous_parameters = theme.materialParameters();
    defer _ = theme.setMaterialParameters(previous_parameters.transparency, previous_parameters.blur);
    _ = theme.setMaterialParameters(75, 16);
    const auth_view = @import("ui/auth_challenge_view.zig");
    const auth = auth_view.auth;
    const old_name = theme.currentName();
    const old_material = theme.materialVisible();
    defer {
        theme.select(old_name);
        _ = theme.setMaterialVisible(old_material);
    }
    for ([_]auth.Presentation{ .protected_form, .otp_modal }) |presentation| {
        theme.select(.dark);
        _ = theme.setMaterialVisible(false);
        const a = std.testing.allocator;
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        cx.setViewport(1440, 900);
        try cx.setTestFrameStep(16);
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const source = try layers.View.mount(cx, scope);
        try cx.root.?.appendChild(a, source.root);
        // The connection dialog and inline form reveal the same global layer.
        const parent = try ui.box(cx, .{ .width = .{ .px = 620 }, .height = .{ .px = 620 }, .background = theme.current().overlay }, .{});
        try cx.root.?.appendChild(a, parent);
        try source.isolate(scope, parent);
        var context: u8 = 0;
        const view = try auth_view.View.mount(cx, scope, .{ .context = &context, .submit = authSubmit, .cancel = authCancel });
        try parent.appendChild(a, view.root);
        try view.setMaterial(source);
        var bridge: auth.InteractiveBridge = .{};
        _ = try bridge.offerChallenge(.{
            .key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(9), .generation = 3 } }, .operation_id = 7, .attempt_id = 2 },
            .hop_index = 1,
            .kind = .keyboard_interactive,
            .endpoint_identity = .{ .host = "target.example", .user = "operator", .port = 2222 },
            .prompts = &.{.{ .text = "Verification code:", .echo = false }},
            .presentation = presentation,
            .presentation_config_revision = 4,
        });
        try view.show(bridge.snapshot().?);
        _ = frame(cx);
        cx.setFocus(view.fields[0].input.input_container);
        cx.handleTextInput("654321");
        const input = view.fields[0].input.state;
        const form = view.form.?;
        const chrome = if (view.modal) |modal| modal.dialog else parent;
        for (chrome.children.items) |child| try std.testing.expect(!layers.isSurface(child));
        for ([_]bool{ false, true, false }) |enabled| {
            for ([_]theme.Name{ .dark, .light }) |name| {
                theme.select(name);
                _ = theme.setMaterialVisible(enabled);
                cx.setTheme(theme.widgetTheme(name));
                parent.setBackground(theme.current().overlay);
                try view.retheme();
                try source.update(if (enabled) .{ .id = 777, .width = 2, .height = 2 } else null, .{ .background = .{ .enabled = enabled, .path = "/fixture", .fit = .fill, .transparency = 35 } }, 1440, 900);
                const items = frame(cx);
                try std.testing.expectEqual(ui.Color.TRANSPARENT, form.getBackground());
                try std.testing.expectEqual(theme.current().overlay, chrome.getBackground());
                try std.testing.expectEqual(input, view.fields[0].input.state);
                try std.testing.expectEqualStrings("654321", input.getText());
                try std.testing.expectEqual(ui.widgets.input.InputType.password, input.input_type);
                try std.testing.expect(!view.submit_disabled.peek());
                try std.testing.expectEqual(theme.current().well, view.fields[0].input.input_container.getBackground());
                var projected: usize = 0;
                var opaque_chrome = false;
                for (items) |item| switch (item) {
                    .image_quad => |q| {
                        if (q.texture_id == 777) projected += 1;
                    },
                    .fill_rect => |fill| {
                        // A content-sized fill would cover the inherited image.
                        try std.testing.expect(fill.header.node_id != form.id);
                        if (fill.header.node_id == chrome.id and fill.color.a == 255) opaque_chrome = true;
                    },
                    else => {},
                };
                try std.testing.expectEqual(if (enabled) @as(usize, 1) else 0, projected);
                try std.testing.expect(!opaque_chrome);
            }
        }
    }
}

test "global material component roles preserve theme action hues and material alpha" {
    const saved_colors = theme.baseColors();
    const saved_parameters = theme.materialParameters();
    defer {
        var tokens: @import("config/theme_registry.zig").UiTokens = undefined;
        inline for (@typeInfo(@TypeOf(saved_colors)).@"struct".field_names) |field| {
            const color = @field(saved_colors, field);
            @field(tokens, field) = (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
        }
        theme.selectTokens(tokens);
        _ = theme.setMaterialParameters(saved_parameters.transparency, saved_parameters.blur);
    }
    const bubble = @import("ui/ai_assistant_styles.zig");
    const strip = @import("ui/ai_strip_styles.zig");
    const recent = @import("ui/ai_empty_styles.zig");
    const close = @import("ui/local_close_styles.zig");
    const sessions = @import("ui/ai_sessions_styles.zig");
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        for ([_]f32{ 0, 50, 100 }) |transparency| {
            _ = theme.setMaterialParameters(transparency, transparency * 0.48);
            const c = theme.current();
            const user = bubble.userBubble(572);
            try std.testing.expectEqual(c.action_accent.withAlpha(c.overlay.a), user.background);
            try std.testing.expectEqual(c.action_accent.withAlpha(c.overlay.a), user.gradient.?.from);
            try std.testing.expectEqual(c.action_accent_2.withAlpha(c.overlay.a), user.gradient.?.to);
            try std.testing.expectEqual(ui.Color.TRANSPARENT, recent.recent().background);
            try std.testing.expectEqual(c.surface_2, strip.lip(theme.widgetTheme(theme.currentName())).background);
            try std.testing.expectEqual(@max(12, theme.materialParameters().blur), strip.lip(theme.widgetTheme(theme.currentName())).glass.?.backdrop_blur);
            for ([_]bool{ false, true }) |active| {
                try std.testing.expectEqual(c.surface_2.a, strip.activeLip(active).gradient.?.from.a);
                try std.testing.expectEqual(c.surface_2.a, strip.activeLip(active).gradient.?.to.a);
            }
            // Destructive actions retain a separate theme warning hue, at full fill.
            try std.testing.expectEqual(c.action_danger, close.button(112, true).background);
            try std.testing.expectEqual(c.action_danger, sessions.control(true).background);
            try std.testing.expectEqual(theme.actionForeground(c.action_danger), sessions.control(true).text_color);
        }
    }
}
