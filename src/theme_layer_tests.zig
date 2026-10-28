//! Global appearance regression checks on retained, real production views.
const std = @import("std");
const ui = @import("ui");
const theme = @import("ui/app_theme.zig");
const publication = @import("ui/shell_styles.zig").ThemePublication;
const Close = @import("ui/local_close_view.zig");
const Transfer = @import("ui/transfer_panel.zig");

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
    const hint = try ui.widgets.Tooltip(.{ .text = "Model metadata", .open = open }).mount(w.scope, w.cx);
    try menu.content.appendChild(w.cx.allocator, hint.wrapper);
    const root_hint = try ui.widgets.Tooltip(.{ .text = "Workspace metadata", .open = open }).mount(w.scope, w.cx);
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
            try std.testing.expectEqual(ui.Color.TRANSPARENT, menu.chrome.style.border.color);
            try std.testing.expectEqual(@as(f32, 0), menu.chrome.style.outline().?.width);
            try std.testing.expect(menu.chrome.getBackground().a > shell.getBackground().a);
            try std.testing.expect(hint.content.getBackground().a > menu.chrome.getBackground().a);
            try std.testing.expectEqual(@as(f32, 12), hint.content.style.glass_params().?.backdrop_blur);
        }
    }
    // Reparenting the same widgets changes material, without remount or type change.
    w.cx.detachChild(shell, menu.wrapper);
    try w.cx.root.?.appendChild(w.cx.allocator, menu.wrapper);
    w.frame();
    try std.testing.expectEqual(theme.layerBackground(1), menu.chrome.getBackground());
    try std.testing.expectEqual(theme.layerBackground(2), hint.content.getBackground());
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
