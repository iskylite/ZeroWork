//! Global appearance regression checks on retained, real production views.
comptime {
    _ = @import("material_performance_tests.zig");
}
const std = @import("std");
const ui = @import("ui");
const theme = @import("ui/app_theme.zig");
const publication = @import("ui/shell_styles.zig").ThemePublication;
const Close = @import("ui/local_close_view.zig");
const Transfer = @import("ui/transfer_panel.zig");

test "floating shadows unify tooltip popover modal and retained panels" {
    const previous = theme.currentName();
    defer theme.select(previous);
    const w = try Window.init();
    defer w.deinit();
    const materials = @import("ui/layer_materials.zig");
    try materials.Policy.mount(w.cx, w.scope);
    const panel = try ui.boxStyled(w.cx, @import("ui/ai_assistant_styles.zig").panel, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, panel);
    const open = try w.scope.createSignal(bool, true);
    const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .enter_transition = .none, .exit_transition = .none, .width = 240 }).mount(w.scope, w.cx);
    try panel.appendChild(w.cx.allocator, popup.wrapper);
    const hint = try ui.widgets.Tooltip(.{ .text = "Floating shadow", .open = open }).mount(w.scope, w.cx);
    try popup.content.appendChild(w.cx.allocator, hint.wrapper);
    const modal = try ui.widgets.Modal(.{ .open = open, .width = @as(f32, 300), .enter_transition = .none, .exit_transition = .none }).mount(w.scope, w.cx);
    if (!modal.portaled) try w.cx.root.?.appendChild(w.cx.allocator, modal.overlay);
    // A material body fills the dialog but must not cast a second shadow.
    materials.overlay(modal.body);
    const card = try ui.box(w.cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 }, .background = theme.popupAction() }, .{});
    materials.card(card, .action);
    try panel.appendChild(w.cx.allocator, card);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        w.publish.publish(w.cx, theme.widgetTheme(name));
        for (0..2) |_| {
            open.set(false);
            w.frame();
            open.set(true);
            w.frame();
            try std.testing.expectEqual(ui.Color.TRANSPARENT, modal.overlay.getBackground());
            for ([_]*ui.Node{ panel, popup.chrome, hint.content, modal.dialog }) |node| {
                const shadows = node.style.shadowSlice();
                try std.testing.expectEqual(@as(usize, 1), shadows.len);
                try std.testing.expectEqual(theme.floatingShadow(), shadows[0]);
            }
            try std.testing.expectEqual(@as(usize, 0), card.style.shadowSlice().len);
            try std.testing.expectEqual(@as(usize, 0), modal.body.style.shadowSlice().len);
        }
    }
}

test "material snapshot ignores content clipped by a collapsed accordion" {
    const w = try Window.init();
    defer w.deinit();
    const clip = try ui.box(w.cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 0 }, .overflow_hidden = true }, .{});
    const child = try ui.box(w.cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 60 } }, .{});
    try clip.appendChild(w.cx.allocator, child);
    try w.cx.root.?.appendChild(w.cx.allocator, clip);
    w.frame();
    try std.testing.expect(@import("ui/material_geometry.zig").snapshot(w.cx, child) == null);
    clip.setStyle(w.cx.allocator, .height, .{ .px = 60 });
    w.frame();
    try std.testing.expect(@import("ui/material_geometry.zig").snapshot(w.cx, child) != null);
}

test "floating text stays readable over changing video and terminal backdrops" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    const w = try Window.init();
    defer w.deinit();
    const materials = @import("ui/layer_materials.zig");
    try materials.Policy.mount(w.cx, w.scope);
    const backdrop = try ui.box(w.cx, .{ .position = .absolute, .width = .{ .px = 700 }, .height = .{ .px = 700 } }, .{});
    materials.variableBackdrop(backdrop);
    try w.cx.root.?.appendChild(w.cx.allocator, backdrop);
    const open = try w.scope.createSignal(bool, true);
    const menu = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .enter_transition = .none, .exit_transition = .none, .width = 200 }).mount(w.scope, w.cx);
    menu.wrapper.setStyleInline(w.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 100 } } });
    try menu.trigger.appendChild(w.cx.allocator, try ui.box(w.cx, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 } }, .{}));
    try menu.content.appendChild(w.cx.allocator, try ui.text(w.cx, "Readable menu", .{}));
    try w.cx.root.?.appendChild(w.cx.allocator, menu.wrapper);
    const contrast = @import("ui/theme_states.zig").contrast;
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        for ([_]f32{ 0, 75, 100 }) |t| {
            _ = theme.setMaterialParameters(t, 0);
            w.publish.publish(w.cx, theme.widgetTheme(theme.currentName()));
            w.frame();
            const fill = menu.chrome.getBackground();
            const base = theme.baseColors();
            for ([_]ui.Color{ ui.Color.BLACK, ui.Color.WHITE }) |behind| {
                const composed = ui.Color.lerp(behind, fill.withAlpha(255), @as(f32, @floatFromInt(fill.a)) / 255);
                for ([_]ui.Color{ base.fg_1, base.fg_2 }) |ink| try std.testing.expect(contrast(composed, ink) >= 4.5);
            }
            if (t == 0) try std.testing.expectEqual(@as(u8, 255), fill.a);
        }
    }
    backdrop.setStyleInline(w.cx.allocator, .{ .inset = .{ .left = .{ .px = 1000 }, .top = .{ .px = 700 } }, .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    w.frame();
    try std.testing.expectEqual(theme.layerAlpha(1), menu.chrome.getBackground().a);
}

test "floating material follows portaled owners rather than widget kinds" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    const w = try Window.init();
    defer w.deinit();
    try @import("ui/layer_materials.zig").Policy.mount(w.cx, w.scope);
    const shell = try ui.box(w.cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 456 }, .background = theme.current().overlay, .glass = theme.overlayGlass() }, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, shell);
    const open = try w.scope.createSignal(bool, true);
    const menu = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .enter_transition = .none, .exit_transition = .none, .width = 336 }).mount(w.scope, w.cx);
    menu.chrome.setStyleInline(w.cx.allocator, .{ .outline = .{ .width = 1, .color = ui.Color.WHITE } });
    menu.chrome.setBorderColor(ui.Color.WHITE);
    try shell.appendChild(w.cx.allocator, menu.wrapper);
    const independent = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .enter_transition = .none, .exit_transition = .none, .width = 220 }).mount(w.scope, w.cx);
    independent.wrapper.setStyleInline(w.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1000 }, .top = .{ .px = 100 } } });
    try w.cx.root.?.appendChild(w.cx.allocator, independent.wrapper);
    const inner_card = try ui.box(w.cx, .{ .background = theme.popupInset(), .width = .fill(), .height = .{ .px = 32 } }, .{});
    try menu.content.appendChild(w.cx.allocator, inner_card);
    const hint = try ui.widgets.Tooltip(.{ .text = "Model metadata", .open = open }).mount(w.scope, w.cx);
    try inner_card.appendChild(w.cx.allocator, hint.wrapper);
    const root_hint = try ui.widgets.Tooltip(.{ .text = "Workspace metadata", .open = open }).mount(w.scope, w.cx);
    root_hint.wrapper.setStyleInline(w.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1000 }, .top = .{ .px = 650 } } });
    try w.cx.root.?.appendChild(w.cx.allocator, root_hint.wrapper);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        for ([_]f32{ 0, 25, 75, 100 }) |t| {
            theme.select(name);
            _ = theme.setMaterialParameters(t, 0);
            shell.setBackground(theme.layerBackground(1));
            w.publish.publish(w.cx, theme.widgetTheme(name));
            w.frame();
            try std.testing.expectEqual(theme.layerBackground(2), menu.chrome.getBackground());
            try std.testing.expectEqual(theme.layerBackground(3), hint.content.getBackground());
            try std.testing.expectEqual(theme.layerBackground(1), root_hint.content.getBackground());
            try std.testing.expectEqual(theme.layerBackground(1), independent.chrome.getBackground());
            try std.testing.expectEqual(ui.Color.TRANSPARENT, menu.chrome.style.border.color);
            try std.testing.expectEqual(@as(f32, 0), menu.chrome.style.outline().?.width);
            try std.testing.expect(menu.chrome.getBackground().a >= shell.getBackground().a);
            try std.testing.expect(hint.content.getBackground().a >= menu.chrome.getBackground().a);
            try std.testing.expectEqual(@as(f32, 12), hint.content.style.glass_params().?.backdrop_blur);
        }
    }
    // Reopening the retained nested surface keeps its real L3 owner chain.
    open.set(false);
    w.frame();
    open.set(true);
    w.frame();
    try std.testing.expectEqual(theme.layerBackground(2), menu.chrome.getBackground());
    try std.testing.expectEqual(theme.layerBackground(3), hint.content.getBackground());
    // Reparenting the same widgets changes material, without remount or type change.
    w.cx.detachChild(shell, menu.wrapper);
    menu.wrapper.setStyleInline(w.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 800 }, .top = .{ .px = 400 } } });
    try w.cx.root.?.appendChild(w.cx.allocator, menu.wrapper);
    w.frame();
    try std.testing.expectEqual(theme.layerBackground(1), menu.chrome.getBackground());
    try std.testing.expectEqual(theme.layerBackground(2), hint.content.getBackground());
    _ = theme.setMaterialParameters(100, 24);
    w.publish.publish(w.cx, theme.widgetTheme(theme.currentName()));
    w.frame();
    for ([_]*ui.Node{ menu.chrome, independent.chrome, hint.content, root_hint.content }) |node|
        try std.testing.expectEqual(@as(f32, 24), node.style.backdrop_blur());
    open.set(false);
    w.frame();
    open.set(true);
    w.frame();
    try std.testing.expectEqual(theme.layerBackground(1), independent.chrome.getBackground());
    try std.testing.expectEqual(theme.layerBackground(2), hint.content.getBackground());
}

test "actual material cards count painted parents while transparent layout wrappers add no depth" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.sauber);
    _ = theme.setMaterialParameters(50, 24);
    const w = try Window.init();
    defer w.deinit();
    const materials = @import("ui/layer_materials.zig");
    try materials.Policy.mount(w.cx, w.scope);
    const group = try ui.box(w.cx, @import("ui/sidebar_styles.zig").groupCard(), .{});
    materials.card(group, .surface_2);
    try w.cx.root.?.appendChild(w.cx.allocator, group);
    const assistant = try ui.boxStyled(w.cx, @import("ui/ai_assistant_styles.zig").panel, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, assistant);
    const layout = try ui.box(w.cx, .{}, .{});
    try assistant.appendChild(w.cx.allocator, layout);
    const result = try ui.boxStyled(w.cx, @import("ui/ai_tool_results_styles.zig").card, .{});
    materials.card(result, .action);
    try layout.appendChild(w.cx.allocator, result);
    const output = try ui.box(w.cx, .{ .background = theme.popupInset() }, .{});
    materials.card(output, .control);
    try result.appendChild(w.cx.allocator, output);
    const open = try w.scope.createSignal(bool, true);
    const hint = try ui.widgets.Tooltip(.{ .text = "Output detail", .open = open }).mount(w.scope, w.cx);
    try output.appendChild(w.cx.allocator, hint.wrapper);
    w.frame();
    try std.testing.expectEqual(@as(u8, 51), group.getBackground().a);
    try std.testing.expectEqual(group.getBackground().a, assistant.getBackground().a);
    try std.testing.expectEqual(@as(u8, 64), result.getBackground().a);
    try std.testing.expectEqual(@as(u8, 85), output.getBackground().a);
    try std.testing.expectEqual(@as(u8, 128), hint.content.getBackground().a);
    try std.testing.expectEqual(@as(u8, 0), layout.getBackground().a);
    theme.select(.dark);
    w.publish.publish(w.cx, theme.widgetTheme(.dark));
    w.frame();
    try std.testing.expectEqual(theme.current().surface_2.withAlpha(theme.layerAlpha(1)), group.getBackground());
    try std.testing.expectEqual(theme.popupAction().withAlpha(theme.layerAlpha(2)), result.getBackground());
    try std.testing.expectEqual(theme.popupInset().withAlpha(theme.layerAlpha(3)), output.getBackground());
    _ = theme.setMaterialParameters(100, 0);
    const file_card = try ui.boxStyled(w.cx, @import("ui/file_workspace_styles.zig").card, .{});
    materials.card(file_card, .surface_1);
    try w.cx.root.?.appendChild(w.cx.allocator, file_card);
    w.frame();
    try std.testing.expectEqual(@as(u8, 51), file_card.getBackground().a);
}

const Window = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    publish: *publication,
    fn init() !Window {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(1440, 900);
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const publish = try cx.bindState(publication, .{});
        publish.publish(cx, theme.widgetTheme(theme.currentName()));
        return .{ .cx = cx, .scope = scope, .publish = publish };
    }
    fn frame(self: Window) void {
        for (0..6) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn apply(self: Window, name: theme.Name, material: bool) void {
        theme.select(name);
        _ = theme.setMaterialVisible(material);
        self.publish.publish(self.cx, theme.widgetTheme(name));
        self.frame();
    }
    fn deinit(self: Window) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};

const Receipt = struct {
    calls: usize = 0,
    id: @import("ui/session_lifecycle.zig").SessionId = 0,
    accepted: bool = false,
    fn resolve(raw: *anyopaque, id: @import("ui/session_lifecycle.zig").SessionId, accepted: bool) void {
        const self: *Receipt = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.id = id;
        self.accepted = accepted;
    }
};

test "global appearance retained local close follows hidden and visible theme publication without resolving" {
    const previous = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const w = try Window.init();
    defer w.deinit();
    var receipt: Receipt = .{};
    const view = try Close.View.mount(w.cx, w.scope, .{ .context = &receipt, .resolve = Receipt.resolve });
    w.frame();
    const identity_id = view.identity.id;
    w.apply(.light, false);
    try view.show(410, null);
    w.frame();
    try std.testing.expectEqual(theme.current().fg_1, view.identity.getText().?.color);
    try std.testing.expectEqual(theme.current().fg_1, view.risk_title.getText().?.color);
    try std.testing.expectEqual(theme.current().fg_2, view.risk_detail.getText().?.color);
    try std.testing.expectEqual(theme.current().fg_2, view.extra_text.getText().?.color);
    const focus = w.cx.focus_manager.getFocused();
    w.apply(.sauber, true);
    try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
    try std.testing.expectEqual(theme.popupAction(), view.risk.getBackground());
    try std.testing.expectEqual(theme.current().fg_1, view.identity.getText().?.color);
    try std.testing.expectEqual(identity_id, view.identity.id);
    try std.testing.expectEqual(focus, w.cx.focus_manager.getFocused());
    try std.testing.expectEqual(@as(?@import("ui/session_lifecycle.zig").SessionId, 410), view.session);
    try std.testing.expectEqual(@as(usize, 0), receipt.calls);
    try std.testing.expectEqual(@as(f32, 480), view.dialog.globalRect().w);
    try std.testing.expectEqual(@as(f32, 220), view.dialog.globalRect().h);
    w.apply(.dark, false);
    try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
    try std.testing.expectEqual(theme.current().fg_1, view.risk_title.getText().?.color);
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        w.publish.publish(w.cx, theme.widgetTheme(theme.currentName()));
        w.frame();
        try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, view.identity.getText().?.color);
        try std.testing.expectEqual(theme.popupAction(), view.risk.getBackground());
        try std.testing.expectEqual(identity_id, view.identity.id);
        try std.testing.expectEqual(@as(usize, 0), receipt.calls);
    }
    view.cancel();
    try std.testing.expectEqual(@as(usize, 1), receipt.calls);
    try std.testing.expectEqual(@as(@import("ui/session_lifecycle.zig").SessionId, 410), receipt.id);
    try std.testing.expect(!receipt.accepted);
}

test "global appearance transfer confirmation repaint keeps captured intent and edited options" {
    const previous = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const w = try Window.init();
    defer w.deinit();
    var panel: Transfer.Panel = .{};
    const root = try panel.mount(w.cx, w.scope);
    try w.cx.root.?.appendChild(w.cx.allocator, root);
    const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(99), .generation = 7 };
    panel.show(.{ .mode = .download, .owner = owner, .endpoint = "original-host", .host_name = "Original", .sources = &.{"/immutable.bin"}, .local_dir = "/owned", .md5 = false });
    w.frame();
    const md5 = findText(panel.card, "MD5 校验") orelse return error.MissingMd5Control;
    const rect = md5.globalRect();
    w.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    w.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    w.frame();
    try std.testing.expect(panel.md5);
    panel.rename_sig.set("kept.bin");
    w.cx.setFocus(panel.local_input.input_container);
    const focus = w.cx.focus_manager.getFocused();
    const node_id = panel.card.id;
    w.apply(.light, true);
    // This is the production main appearance-publication integration point.
    panel.retheme();
    w.frame();
    try std.testing.expectEqual(theme.current().overlay, panel.card.getBackground());
    try std.testing.expectEqual(theme.current().fg_1, panel.title.getText().?.color);
    try std.testing.expectEqual(node_id, panel.card.id);
    try std.testing.expectEqual(focus, w.cx.focus_manager.getFocused());
    try std.testing.expectEqual(owner, panel.captured_owner.?);
    try std.testing.expectEqualStrings("kept.bin", panel.rename_sig.peek());
    try std.testing.expect(panel.md5);
    try std.testing.expectEqualStrings("/owned", panel.local_dir_sig.peek());
    try std.testing.expect(panel.isVisible());
}

fn findText(node: *ui.Node, text: []const u8) ?*ui.Node {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, text)) return node;
    for (node.children.items) |child| if (findText(child, text)) |found| return found;
    return null;
}

test {
    _ = @import("ui/app_theme.zig");
    _ = @import("ui/shell_styles.zig");
    _ = @import("status_detail_tests.zig");
    _ = @import("auxiliary_appearance_tests.zig");
}

test "global appearance worker frame default text repaints while ANSI and archived history stay intact" {
    const Terminal = @import("ui/terminal_view.zig").TerminalViewNode;
    const Slot = @import("vt/text_slot.zig").TextSlot;
    const Wire = @import("vt/text_frame.zig");
    const Styled = @import("vt/text_projection_styled.zig");
    const previous = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const w = try Window.init();
    defer w.deinit();
    var view = try Terminal.mount(w.cx);
    defer view.releaseBuffers(w.cx);
    try w.cx.root.?.appendChild(w.cx.allocator, view.root);
    view.setThemeColors(theme.current().fg_1, theme.current().border, theme.current().accent);
    var slot = try Slot.init(std.testing.allocator, 512);
    defer slot.deinit(std.testing.allocator);
    var header: [Wire.header_bytes]u8 = undefined;
    var span_bytes: [Wire.span_wire_bytes]u8 = undefined;
    const span: Styled.Span = .{ .start = 6, .end = 9, .color = 0xff0000ff, .bg = 0 };
    Wire.encodeSpans(&span_bytes, &.{span});
    var scratch: [512]u8 align(4) = undefined;
    var seen: u64 = 0;
    for ([_][]const u8{ "plain red\nfirst", "plain red\nlatest" }) |text| {
        Wire.encodeHeader(&header, .{}, 40, 2, 1, text.len);
        _ = try slot.publishParts(&.{ &header, &span_bytes, text });
        try std.testing.expect(try view.consumeText(w.cx, &slot, &seen, &scratch));
    }
    w.frame();
    const row = view.row_nodes[0].?;
    const row_id = row.id;
    try std.testing.expectEqual(theme.current().fg_1, row.getText().?.color);
    try std.testing.expect(hasRed(row));
    view.bindArchived();
    try std.testing.expect(view.openHistory());
    w.frame();
    const history_selected = view.history.selected;
    const text_before = try std.testing.allocator.dupe(u8, row.getText().?.content);
    defer std.testing.allocator.free(text_before);
    const focus = w.cx.focus_manager.getFocused();
    w.apply(.light, true);
    // Same in-place call used by the main global publication for SSH tabs.
    view.setThemeColors(theme.current().fg_1, theme.current().border, theme.current().accent);
    w.frame();
    try std.testing.expectEqual(theme.current().fg_1, row.getText().?.color);
    try std.testing.expectEqual(row_id, row.id);
    try std.testing.expectEqualStrings(text_before, row.getText().?.content);
    try std.testing.expect(hasRed(row));
    try std.testing.expectEqual(history_selected, view.history.selected);
    try std.testing.expectEqual(focus, w.cx.focus_manager.getFocused());
    try std.testing.expect(!view.tombstone.allowsRemoteInput());
}

fn hasRed(node: *ui.Node) bool {
    const props = node.getText() orelse return false;
    for (props.spans) |span| if (span.color) |color| if (ui.Color.eql(color, ui.Color.rgb(255, 0, 0))) return true;
    return false;
}

fn fixed(comptime T: type, value: []const u8) T {
    var result: T = std.mem.zeroes(T);
    @memcpy(result.bytes[0..value.len], value);
    result.len = value.len;
    return result;
}
const HostApprovalFixture = struct {
    w: Window,
    view: *@import("ui/ai_host_approval_view.zig").View,
    fn ignore(_: *anyopaque, _: u64, _: [32]u8, _: bool) !void {}
    fn init() !HostApprovalFixture {
        const w = try Window.init();
        errdefer w.deinit();
        const view = try @import("ui/ai_host_approval_view.zig").View.mount(w.cx, w.scope, .{ .context = w.cx, .on_decision = ignore });
        try w.cx.root.?.appendChild(w.cx.allocator, view.root);
        const Snapshot = @import("ai/host_approval.zig").Snapshot;
        const source: Snapshot = .{
            .kind = .network_url,
            .sequence = 19,
            .target = fixed(@FieldType(Snapshot, "target"), "https://example.com/docs"),
            .detail = fixed(@FieldType(Snapshot, "detail"), "https://example.com/docs?version=1"),
            .canonical_url = fixed(@FieldType(Snapshot, "canonical_url"), "https://example.com/docs?version=1"),
            .tool = fixed(@FieldType(Snapshot, "tool"), "host.fetch_url"),
            .impact = fixed(@FieldType(Snapshot, "impact"), "仅读取本次批准的网页。"),
            .call = fixed(@FieldType(Snapshot, "call"), "theme-fixture"),
            .requested_url = fixed(@FieldType(Snapshot, "requested_url"), "https://example.com/docs?version=1"),
            .context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 },
            .authority = .local_network_read,
            .operation_id = 1,
            .turn_id = 1,
            .arguments_hash = @splat(0),
            .canonical_arguments_hash = @splat(0),
            .network_policy_revision = 1,
            .created_at_ms = 0,
            .expires_at_ms = 120000,
        };
        try view.update(source);
        for (0..5) |_| w.frame();
        return .{ .w = w, .view = view };
    }
};
test "retained host approval paint matches every builtin without replacing its request" {
    const previous = theme.currentName();
    defer theme.select(previous);
    theme.select(.dark);
    const retained = try HostApprovalFixture.init();
    defer retained.w.deinit();
    const request = retained.view.sequence;
    const identity = retained.view.url;
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        retained.w.publish.publish(retained.w.cx, theme.widgetTheme(theme.currentName()));
        for (0..5) |_| retained.w.frame();
        const fresh = try HostApprovalFixture.init();
        defer fresh.w.deinit();
        errdefer std.debug.print("theme={s}\n", .{id});
        try @import("ui_theme_test_support.zig").expectPaintEqual(retained.view.root, fresh.view.root);
        try std.testing.expectEqual(request, retained.view.sequence);
        try std.testing.expectEqual(identity, retained.view.url);
    }
}

fn materialPatchTransmission(root: *ui.Node, x: f32, y: f32, transmission: *f32) usize {
    var count: usize = 0;
    for (root.children.items) |patch| {
        if (patch.style.display == .none) continue;
        const r = patch.globalRect();
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) {
            transmission.* *= 1 - @as(f32, @floatFromInt(patch.getBackground().a)) / 255;
            count += 1;
        }
    }
    return count;
}

test "material portal crossing a rounded owner reaches one final opacity inside and outside" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.sauber);
    _ = theme.setMaterialParameters(50, 0);
    const w = try Window.init();
    defer w.deinit();
    const materials = @import("ui/layer_materials.zig");
    try materials.Policy.mount(w.cx, w.scope);
    const parent = try ui.box(w.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 200 }, .top = .{ .px = 200 } }, .width = .{ .px = 240 }, .height = .{ .px = 200 }, .border = .{ .radius = 24 }, .background = theme.current().surface_2 }, .{});
    materials.card(parent, .surface_2);
    try w.cx.root.?.appendChild(w.cx.allocator, parent);
    const popup = try ui.box(w.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = -20 }, .top = .{ .px = -20 } }, .width = .{ .px = 340 }, .height = .{ .px = 140 }, .background = theme.popupAction(), .border = .{ .radius = 12 } }, .{});
    materials.card(popup, .action);
    try parent.appendChild(w.cx.allocator, popup);
    w.frame();
    const compensation = popup.children.items[0];
    try std.testing.expectEqualStrings("appearance.material.compensation", compensation.meta.ownership.meta.test_id.?);
    _ = w.cx.render();
    const Case = struct { x: f32, y: f32, parent_covered: bool };
    for ([_]Case{
        .{ .x = 300.25, .y = 250.25, .parent_covered = true },
        .{ .x = 480.25, .y = 250.25, .parent_covered = false },
        .{ .x = 202.25, .y = 202.25, .parent_covered = false },
    }) |point| {
        var transmission: f32 = 0.5;
        if (point.parent_covered) transmission *= 1 - @as(f32, @floatFromInt(parent.getBackground().a)) / 255;
        transmission *= 1 - @as(f32, @floatFromInt(popup.getBackground().a)) / 255;
        const extra_count = materialPatchTransmission(compensation, point.x, point.y, &transmission);
        try std.testing.expectEqual(@as(usize, if (point.parent_covered) 0 else 1), extra_count);
        try std.testing.expectApproxEqAbs(@as(f32, 0.3), transmission, 0.002);
    }
    // Moving wholly inside removes correction without remounting foreground.
    popup.setStyleInline(w.cx.allocator, .{ .inset = .{ .left = .{ .px = 40 }, .top = .{ .px = 40 } }, .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    w.frame();
    try std.testing.expectEqual(@as(usize, 0), popup.children.items.len);
}

test "material overlapping sibling cards preserve one L1 opacity instead of stacking fills" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.sauber);
    _ = theme.setMaterialParameters(50, 0);
    const w = try Window.init();
    defer w.deinit();
    const materials = @import("ui/layer_materials.zig");
    try materials.Policy.mount(w.cx, w.scope);
    const lower = try ui.box(w.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 200 }, .top = .{ .px = 200 } }, .width = .{ .px = 240 }, .height = .{ .px = 200 }, .background = theme.current().surface_2 }, .{});
    materials.card(lower, .surface_2);
    try w.cx.root.?.appendChild(w.cx.allocator, lower);
    const upper = try ui.box(w.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 300 }, .top = .{ .px = 180 } }, .width = .{ .px = 240 }, .height = .{ .px = 180 }, .background = theme.popupAction() }, .{});
    materials.card(upper, .action);
    try w.cx.root.?.appendChild(w.cx.allocator, upper);
    w.frame();
    try std.testing.expectEqual(@as(u8, 0), upper.getBackground().a);
    const compensation = upper.children.items[0];
    _ = w.cx.render();
    for ([_]f32{ 350.25, 500.25 }) |x| {
        var transmission: f32 = 0.5;
        if (x < 440) transmission *= 1 - @as(f32, @floatFromInt(lower.getBackground().a)) / 255;
        _ = materialPatchTransmission(compensation, x, 250.25, &transmission);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), transmission, 0.002);
    }
    // Bringing an existing card forward changes painting order without
    // changing topology; the material index must follow the renderer.
    lower.setStyle(w.cx.allocator, .z_index, 5);
    w.frame();
    try std.testing.expectEqual(theme.layerAlpha(1), upper.getBackground().a);
    try std.testing.expectEqual(@as(u8, 0), lower.getBackground().a);
    _ = theme.setMaterialParameters(0, 0);
    w.frame();
    try std.testing.expectEqual(@as(u8, 255), upper.getBackground().a);
}

test "material retained assistant replays missed themes before first open and after collapse" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.dark);
    _ = theme.setMaterialParameters(0, 0);
    const w = try Window.init();
    defer w.deinit();
    const holder = try ui.box(w.cx, .{ .position = .absolute, .width = .{ .px = 600 }, .height = .{ .px = 456 } }, .{});
    const assistant = try ui.boxStyled(w.cx, @import("ui/ai_assistant_styles.zig").panel, .{});
    const title = try ui.textStyled(w.cx, @import("ui/ai_assistant_styles.zig").title, "AI 助手");
    try assistant.appendChild(w.cx.allocator, title);
    const draft = try w.scope.createText("保留草稿", .{});
    const editor = try ui.widgets.Textarea(.{ .value = draft, .borderless = true, .rows = 1 }).mountResult(w.scope, w.cx);
    @import("ui/ai_composer_sizing.zig").configure(editor);
    try @import("ui/ai_composer_sizing.zig").bindTheme(w.cx, w.scope, editor);
    try assistant.appendChild(w.cx.allocator, editor.wrapper);
    try holder.appendChild(w.cx.allocator, assistant);
    try w.cx.root.?.appendChild(w.cx.allocator, holder);
    holder.setDisplay(.none);
    _ = try @import("ui/retained_panel.zig").Panel.mount(w.cx, w.scope, w.cx.root.?, holder);
    try @import("ui/layer_materials.zig").Policy.mount(w.cx, w.scope);
    const identity = assistant.id;
    for ([_]theme.Name{ .light, .sauber, .dark }) |name| {
        theme.select(name);
        _ = theme.setMaterialParameters(75, 24);
        w.publish.publish(w.cx, theme.widgetTheme(name));
        holder.setDisplay(.flex);
        const published_version = w.cx.theme_version;
        w.frame();
        try std.testing.expectEqual(published_version, w.cx.theme_version);
        try std.testing.expectEqual(theme.layerBackground(1), assistant.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, title.getText().?.color);
        try std.testing.expectEqual(@as(f32, 24), assistant.style.backdrop_blur());
        try std.testing.expectEqual(identity, assistant.id);
        try std.testing.expectEqualStrings("保留草稿", draft.peek());
        try std.testing.expectEqual(theme.current().fg_1, editor.state.tokens.tokens.color.fg_primary);
        try std.testing.expectEqual(theme.current().fg_1, findText(editor.wrapper, "保留草稿").?.getText().?.color);
        holder.setDisplay(.none);
        w.frame();
        try std.testing.expect(holder.parent == null);
    }
}

test "material floating identity survives stale palette RGB and ignores background capture" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.dark);
    _ = theme.setMaterialParameters(100, 24);
    const w = try Window.init();
    defer w.deinit();
    try @import("ui/layer_materials.zig").Policy.mount(w.cx, w.scope);
    const stale = try ui.box(w.cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 160 }, .background = theme.colors(.light).overlay, .glass = theme.overlayGlass() }, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, stale);
    const capture = try ui.box(w.cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .background = ui.Color.TRANSPARENT, .glass = .{ .backdrop_blur = 24, .capture_current_target = true } }, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, capture);
    w.frame();
    try std.testing.expectEqual(theme.layerBackground(1), stale.getBackground());
    try std.testing.expectEqual(ui.Color.TRANSPARENT, capture.getBackground());
}

test "material production recovery inventory images code and risk cards follow their real owners" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    const w = try Window.init();
    defer w.deinit();
    w.cx.setViewport(1440, 1600);
    try @import("ui/layer_materials.zig").Policy.mount(w.cx, w.scope);
    const assistant = try ui.boxStyled(w.cx, @import("ui/ai_assistant_styles.zig").panel, .{});
    try w.cx.root.?.appendChild(w.cx.allocator, assistant);
    const Callbacks = struct {
        fn recover(_: *anyopaque, _: @import("ui/ai_recovery_view.zig").Envelope) void {}
        fn close(_: *anyopaque, _: @import("ui/session_lifecycle.zig").SessionId, _: bool) void {}
        fn inventory(_: *anyopaque, _: @import("ai/inventory_approval.zig").Ticket, _: @import("ai/inventory_approval.zig").Decision) !void {}
        fn preview(_: *anyopaque, _: @import("ai/image_attachments.zig").ContentRef) !void {}
    };
    const recovery = try @import("ui/ai_recovery_view.zig").mount(w.cx, w.scope, .{ .ticket = .{ .owner = .{ .session = 1 }, .turn = 1 }, .reason = "请求失败", .retries = 0, .max_retries = 3, .retry_enabled = true, .regenerate_enabled = false, .cooldown_seconds = 0 }, .{ .context = w.cx, .enqueue = Callbacks.recover });
    try assistant.appendChild(w.cx.allocator, recovery);
    const inventory = try @import("ui/ai_inventory_grant_view.zig").View.mount(w.cx, w.scope, .{ .context = w.cx, .on_decision = Callbacks.inventory });
    @import("ui/layer_materials.zig").overlay(inventory.root); // Isolation preserves its action role.
    inventory.root.setDisplay(.flex);
    try assistant.appendChild(w.cx.allocator, inventory.root);
    const images = @import("ui/ai_transcript_images.zig");
    var store: images.Store = .{ .allocator = w.cx.allocator };
    defer store.deinit();
    const image_card = try images.mount(w.cx, w.scope, .{ .store = &store, .source = null, .conversation = 1, .turn = 1, .app = null, .preview_context = w.cx, .preview = Callbacks.preview }, .{ .start = 0, .end = 1, .alt = "", .path = "/fixture.png" }, 570);
    try assistant.appendChild(w.cx.allocator, image_card);
    const message = try @import("ui/ai_message_view.zig").mountCode(w.cx, w.scope, "printf hello", "sh");
    try assistant.appendChild(w.cx.allocator, message);
    const code = findLayerTestNode(message, "ai.message.code").?;
    const close = try Close.View.mount(w.cx, w.scope, .{ .context = w.cx, .resolve = Callbacks.close });
    try close.show(1, null);
    var terminal = try @import("ui/terminal_view.zig").TerminalViewNode.mount(w.cx);
    defer terminal.releaseBuffers(w.cx);
    try w.cx.root.?.appendChild(w.cx.allocator, terminal.root);
    try terminal.attachSearch(w.scope);
    terminal.history_bar.?.setDisplay(.flex);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        for ([_]f32{ 0, 25, 75, 100 }) |t| {
            theme.select(name);
            _ = theme.setMaterialParameters(t, 24);
            w.publish.publish(w.cx, theme.widgetTheme(name));
            assistant.setStyleInline(w.cx.allocator, .{ .height = .{ .px = 1300 } });
            w.frame();
            const action = theme.popupAction().withAlpha(theme.layerAlpha(2));
            const control = theme.popupInset().withAlpha(theme.layerAlpha(2));
            try std.testing.expectEqual(action, recovery.getBackground());
            try std.testing.expectEqual(action, inventory.root.getBackground());
            try std.testing.expectEqual(control, image_card.getBackground());
            try std.testing.expectEqual(control, code.getBackground());
            try std.testing.expectEqual(theme.current().fg_1, findLayerTestNode(code, "ai.message.code.text").?.getText().?.color);
            try std.testing.expectEqual(theme.current().fg_2, findLayerTestNode(code, "ai.message.code.language").?.getText().?.color);
            try std.testing.expectEqual(action, close.risk.getBackground());
            try std.testing.expectEqual(theme.current().surface_1.withAlpha(theme.layerAlpha(1)), terminal.history_bar.?.getBackground());
            try std.testing.expectEqual(@as(u8, 255), recovery.children.items[0].children.items[1].getText().?.color.a);
        }
    }
}

fn findLayerTestNode(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (findLayerTestNode(child, id)) |found| return found;
    return null;
}
