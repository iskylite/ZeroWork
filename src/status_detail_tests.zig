const std = @import("std");
const ui = @import("ui");
const View = @import("ui/status_detail_view.zig").View;

test "status popover mounts real widgets and closes when its captured owner changes" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.viewport.width = 1440;
    cx.viewport.height = 900;
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const trigger = try ui.widgets.Button(.{ .label = "网格" }).mount(scope, cx);
    try root.appendChild(cx.allocator, trigger);
    var context: u8 = 0;
    const view = try View.mount(cx, scope, .{ .context = &context });
    try root.appendChild(cx.allocator, view.root);
    var source: @import("ui/status_controller.zig").Projection = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(1) } }, .owner_kind = .local, .source_revision = 1, .identity_label = "本地 · zsh", .encoding = .utf8, .grid = .{ .cols = 80, .rows = 24, .revision = 1 } };
    try view.update(source);
    try view.show(.grid, trigger, 860, false);
    try std.testing.expectEqualStrings("终端网格", view.title.getText().?.content);
    try std.testing.expectEqual(@as(f32, 186), view.chrome.style.height.px);
    source.owner.session.generation = 2;
    try view.update(source);
    try std.testing.expect(view.controller.popover == null);
    try std.testing.expect(!view.open.get());
}

test "local close modal keeps captured session and resolves once after user decision" {
    const Close = @import("ui/local_close_view.zig");
    const SessionId = @import("ui/session_lifecycle.zig").SessionId;
    const Recorder = struct {
        calls: usize = 0,
        id: SessionId = 0,
        accepted: bool = false,
        fn resolve(raw: *anyopaque, id: SessionId, accepted: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.id = id;
            self.accepted = accepted;
        }
    };
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.viewport.width = 1440;
    cx.viewport.height = 900;
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var recorder: Recorder = .{};
    const view = try Close.View.mount(cx, scope, .{ .context = &recorder, .resolve = Recorder.resolve });
    try view.show(41, null);
    try std.testing.expectEqualStrings("无法核实本地进程状态", view.risk_title.getText().?.content);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
    try std.testing.expectError(error.CloseConfirmationAlreadyOpen, view.show(42, null));
    view.cancel();
    view.cancel();
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(SessionId, 41), recorder.id);
    try std.testing.expect(!recorder.accepted);
    try view.show(42, null);
    view.accept();
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqual(@as(SessionId, 42), recorder.id);
    try std.testing.expect(recorder.accepted);
}

test "registry global theme publication preserves RGBA roles beyond three legacy names" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    var registry = try @import("config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    const record = registry.get("nord").?;
    theme.selectTokens(record.ui_tokens);
    const actual = theme.current();
    try std.testing.expectEqual(@as(u8, @intCast(record.ui_tokens.app >> 24)), actual.app.r);
    try std.testing.expectEqual(@as(u8, @intCast(record.ui_tokens.app & 255)), actual.app.a);
    try std.testing.expectEqual(@as(u8, @intCast(record.ui_tokens.selection & 255)), actual.selection.a);
    const widgets = theme.widgetTheme(theme.currentName());
    try std.testing.expectEqual(actual.fg_1, widgets.tokens.color.fg_primary);
    try std.testing.expectEqual(actual.selection, widgets.tokens.color.selection_bg);
}

test {
    _ = @import("ui/local_status_view.zig");
}

test {
    _ = @import("ui/status_theme_view.zig");
}

const StatusFixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    trigger: *ui.Node,
    view: *View,
    themes: usize = 0,
    fn init(self: *StatusFixture) !void {
        const a = std.testing.allocator;
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .trigger = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.trigger = try ui.widgets.Button(.{ .a11y_label = "状态" }).mount(self.scope, self.cx);
        self.trigger.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 376 }, .top = .{ .px = 863 } }, .width = .{ .px = 94 }, .height = .{ .px = 26 } });
        try self.cx.root.?.appendChild(a, self.trigger);
        self.view = try View.mount(self.cx, self.scope, .{ .context = self, .theme = theme });
        try self.cx.root.?.appendChild(a, self.view.root);
        self.cx.layout();
        _ = self.cx.render();
        try self.view.update(projection());
    }
    fn deinit(self: *StatusFixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn theme(raw: *anyopaque) void {
        const self: *StatusFixture = @ptrCast(@alignCast(raw));
        self.themes += 1;
    }
    fn projection() @import("ui/status_controller.zig").Projection {
        return .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(401), .generation = 1 } }, .owner_kind = .local, .source_revision = 1, .identity_label = "本地 · zsh", .encoding = .utf8, .grid = .{ .cols = 132, .rows = 36, .revision = 1 }, .cwd = "/tmp/ZeroWork" };
    }
    fn settle(self: *StatusFixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..20) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn show(self: *StatusFixture, kind: @import("ui/status_controller.zig").Kind, narrow: bool) !void {
        try self.view.show(kind, self.trigger, 860, narrow);
        self.settle();
    }
    fn click(self: *StatusFixture, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    }
};
fn statusText(node: *ui.Node, text: []const u8) bool {
    if (node.getText()) |value| if (std.mem.indexOf(u8, value.content, text) != null) return true;
    for (node.children.items) |child| if (statusText(child, text)) return true;
    return false;
}
fn statusId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (statusId(child, id)) |found| return found;
    return null;
}

test "status popover local identity matches the real cwd and original session at the exact 156 height" {
    var f: StatusFixture = undefined;
    try f.init();
    defer f.deinit();
    var cwd = [_]u8{ '/', 't', 'm', 'p', '/', 'o', 'w', 'n' };
    var source = StatusFixture.projection();
    source.source_revision = 2;
    source.cwd = &cwd;
    try f.view.update(source);
    cwd[1] = 'x';
    try f.show(.identity, false);
    const r = f.view.chrome.globalRect();
    try std.testing.expectEqual(@as(f32, 360), r.w);
    try std.testing.expectEqual(@as(f32, 156), r.h);
    try std.testing.expectEqual(@as(usize, 4), f.view.rows.children.items.len);
    try std.testing.expect(statusText(f.view.rows, "/tmp/own"));
    try std.testing.expect(statusText(f.view.rows, "会话 #401"));
    try std.testing.expect(statusText(f.view.rows, "交互式登录"));
    for ([_]f32{ 46, 70, 94, 118 }, 0..) |offset, index| try std.testing.expectApproxEqAbs(r.y + offset, f.view.rows.children.items[index].globalRect().y, 0.1);
    try std.testing.expectEqual(@as(u16, 500), f.view.title.getText().?.font_weight);
    try std.testing.expectEqual(@as(f32, 24), f.view.close_button.globalRect().w);
    f.cx.setFocus(f.view.close_button);
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expect(f.view.controller.popover == null);
    try std.testing.expect(f.cx.isFocused(f.trigger));
}

test "status popover grid and encoding use exact live typography row spacing and passive facts" {
    var f: StatusFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(.grid, false);
    var r = f.view.chrome.globalRect();
    try std.testing.expectEqual(@as(f32, 186), r.h);
    try std.testing.expectEqual(@as(f32, 32), f.view.rows.children.items[0].globalRect().h);
    const value = f.view.rows.children.items[0].children.items[0];
    try std.testing.expectEqualStrings("132 × 36", value.getText().?.content);
    try std.testing.expectEqual(@as(f32, 18), value.getText().?.font_size);
    try std.testing.expectEqual(@as(u16, 600), value.getText().?.font_weight);
    try std.testing.expect(!value.getText().?.use_monospace_font);
    try std.testing.expectApproxEqAbs(r.y + 46, value.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(r.y + 84, f.view.rows.children.items[1].globalRect().y, 0.1);
    try std.testing.expectEqual(@as(u16, 700), f.view.title.getText().?.font_weight);
    f.view.hide();
    try f.show(.encoding, false);
    r = f.view.chrome.globalRect();
    try std.testing.expectEqual(@as(f32, 148), r.h);
    try std.testing.expectEqual(@as(usize, 3), f.view.rows.children.items.len);
    try std.testing.expect(statusText(f.view.rows, "UTF-8"));
    try std.testing.expect(statusText(f.view.rows, "其他编码"));
    try std.testing.expect(statusText(f.view.rows, "暂不可用"));
    try std.testing.expectApproxEqAbs(r.y + 110, f.view.rows.children.items[2].globalRect().y, 0.1);
    f.click(f.view.rows.children.items[2]);
    try std.testing.expectEqual(@import("ui/status_controller.zig").Kind.encoding, f.view.controller.popover.?.kind);
}

test "status popover SSH more follows wide and narrow ordering with real metrics and keyboard details" {
    var f: StatusFixture = undefined;
    try f.init();
    defer f.deinit();
    var source = StatusFixture.projection();
    source.source_revision = 2;
    source.owner_kind = .ssh;
    source.identity_label = "K8s-Node01";
    source.rtt = .{ .milliseconds = 17 };
    try f.view.update(source);
    try f.show(.more, false);
    try std.testing.expectEqual(@as(f32, 148), f.view.chrome.globalRect().h);
    try std.testing.expectEqualStrings("status.more.rtt", f.view.rows.children.items[0].meta.ownership.meta.test_id.?);
    try std.testing.expect(statusText(f.view.rows.children.items[0], "17ms"));
    try std.testing.expect(statusText(f.view.rows.children.items[1], "UTF-8"));
    try std.testing.expect(statusText(f.view.rows.children.items[2], "132×36"));
    const row = statusId(f.view.rows, "status.more.encoding").?;
    f.cx.setFocus(row);
    f.cx.handleKeyDown(.@"return", .{});
    try f.view.flush();
    f.settle();
    try std.testing.expectEqual(@import("ui/status_controller.zig").Kind.encoding, f.view.controller.popover.?.kind);
    try std.testing.expect(f.view.controller.popover.?.owner.eql(source.owner));
    try std.testing.expectEqual(@as(u64, f.trigger.id), f.view.controller.popover.?.focus_return);
    f.view.hide();
    try f.show(.more, true);
    try std.testing.expectEqual(@as(f32, 180), f.view.chrome.globalRect().h);
    try std.testing.expectEqualStrings("status.more.encoding", f.view.rows.children.items[0].meta.ownership.meta.test_id.?);
    try std.testing.expectEqualStrings("status.more.grid", f.view.rows.children.items[1].meta.ownership.meta.test_id.?);
    try std.testing.expectEqualStrings("status.more.rtt", f.view.rows.children.items[2].meta.ownership.meta.test_id.?);
    try std.testing.expect(statusText(f.view.rows.children.items[3], "应用与全部终端"));
}

test "status popover local more has no fictitious RTT and rejects late old owner actions" {
    var f: StatusFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(.more, true);
    try std.testing.expectEqual(@as(usize, 3), f.view.rows.children.items.len);
    try std.testing.expect(statusId(f.view.rows, "status.more.rtt") == null);
    const original_grid = statusId(f.view.rows, "status.more.grid").?;
    f.click(original_grid);
    try f.view.flush();
    f.settle();
    try std.testing.expectEqual(@import("ui/status_controller.zig").Kind.grid, f.view.controller.popover.?.kind);
    f.view.hide();
    try f.show(.more, true);
    const original_theme = statusId(f.view.rows, "status.more.theme").?;
    var source = StatusFixture.projection();
    source.owner.session.generation = 2;
    try f.view.update(source);
    _ = f.cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, original_theme);
    try std.testing.expectEqual(@as(usize, 0), f.themes);
    try std.testing.expect(f.view.controller.popover == null);
    try std.testing.expect(!f.view.open.peek());
}

test "status popover global theme action closes only its captured menu and follows app scope" {
    var f: StatusFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(.more, true);
    f.click(statusId(f.view.rows, "status.more.theme").?);
    try std.testing.expectEqual(@as(usize, 1), f.themes);
    try std.testing.expect(f.view.controller.popover == null);
    try std.testing.expect(!f.view.open.peek());
    try std.testing.expect(f.cx.isFocused(f.trigger));
    try f.show(.more, false);
    try std.testing.expectEqual(@as(usize, 2), f.view.rows.children.items.len);
    try std.testing.expectEqual(@as(f32, 116), f.view.chrome.globalRect().h);
}

test "status popover local status keyboard triggers retain the selected generation and global theme scope" {
    const Local = @import("ui/local_status_view.zig");
    const Recorder = struct {
        view: *Local.View = undefined,
        kind: ?@import("ui/status_controller.zig").Kind = null,
        owner: ?@import("host/identity.zig").SessionHandle = null,
        themes: usize = 0,
        fn detail(raw: *anyopaque, kind: @import("ui/status_controller.zig").Kind, _: *ui.Node) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kind = kind;
            self.owner = self.view.currentOwner();
        }
        fn theme(raw: *anyopaque, _: *ui.Node) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.themes += 1;
        }
    };
    var f: StatusFixture = undefined;
    try f.init();
    defer f.deinit();
    var recorder: Recorder = .{};
    const view = try Local.View.mount(f.cx, f.scope, .{ .context = &recorder, .detail = Recorder.detail, .theme = Recorder.theme });
    recorder.view = view;
    try f.cx.root.?.appendChild(std.testing.allocator, view.root);
    var value: Local.Update = .{ .owner = .{ .session_id = @fromBackingInt(401), .generation = 1 }, .source_revision = 1, .cwd = "/tmp/ZeroWork", .encoding = .utf8, .grid = .{ .cols = 132, .rows = 36, .revision = 1 } };
    try view.update(value);
    f.cx.layout();
    const Trigger = struct { node: *ui.Node, kind: @import("ui/status_controller.zig").Kind };
    for ([_]Trigger{.{ .node = view.identity_button, .kind = .identity }}) |trigger| {
        f.cx.setFocus(trigger.node);
        f.cx.handleKeyDown(.@"return", .{});
        try std.testing.expectEqual(trigger.kind, recorder.kind.?);
        try std.testing.expect(recorder.owner.?.eql(value.owner));
    }
    value.owner.generation = 2;
    try view.update(value);
    f.cx.setFocus(view.identity_button);
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expect(recorder.owner.?.eql(value.owner));
    f.cx.setFocus(view.theme_button);
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), recorder.themes);
    try std.testing.expectEqual(@as(u64, 2), recorder.owner.?.generation);
}
