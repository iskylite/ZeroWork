//! Actual Cx hit testing and retained widgets; synthetic frozen conflict data,
//! no transport, filesystem writes or native window.
const std = @import("std");
const ui = @import("ui");
const mod = @import("ui/transfer_conflict_view.zig");
const Conflict = mod.Conflict;
const domain = mod.domain;
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 9 };
const key_: domain.Key = .{ .intent_id = 501, .owner = .{ .session = owner }, .original_owner = owner, .entry = 0, .job = 42, .attempt = 1, .revision = 1 };
const local: domain.Endpoint = .{ .local_fs = .{ .binding_id = 12, .binding_generation = 3 } };
const remote: domain.Endpoint = .{ .sftp = .{ .binding_id = 13, .binding_generation = 4, .resource_owner = .{ .session = owner }, .origin_session = owner } };
const context: Conflict.Context = .{ .intent_id = 501, .job = 42, .attempt = 1, .original_owner = owner, .resource_owner = .{ .session = owner }, .source_endpoint = local, .target_endpoint = remote };
const source_metadata: domain.Metadata = .{ .kind = .file, .size = 128 * 1024 * 1024, .modified_at = 1760523480 };
const target_version: domain.TargetVersion = .{ .revision = 7, .metadata = .{ .kind = .file, .size = 124 * 1024 * 1024, .modified_at = 1760459520 } };
fn source() Conflict.Snapshot {
    return .{ .engine_job = 7, .context = context, .pending = .{ .choice = .{ .key = key_, .direction = .upload, .source_endpoint = local, .target_endpoint = remote, .source_path = "/local/release.tar.gz", .source_metadata = source_metadata, .target_path = "/srv/releases/release.tar.gz", .target = .{ .present = target_version }, .selection = .{}, .suggested_path = null, .phase = .waiting, .issue = null } } };
}
fn confirmation(direction: @import("transfer/manager.zig").Direction, ticket: u64, targets: []const domain.OverwriteTarget) Conflict.Snapshot {
    var value = source();
    if (direction == .download) {
        value.context.?.source_endpoint = remote;
        value.context.?.target_endpoint = local;
    }
    value.pending = .{ .overwrite_confirmation = .{ .ticket = .{ .intent_id = 501, .owner = .{ .session = owner }, .id = ticket }, .original_owner = owner, .direction = direction, .endpoint = if (direction == .upload) remote else local, .targets = targets } };
    return value;
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *mod.View,
    decisions: usize = 0,
    pauses: usize = 0,
    last: ?Conflict.Request = null,
    paused: ?domain.Key = null,
    name: [4096]u8 = undefined,
    reject: bool = false,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(860, 480);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        try self.cx.setTestFrameStep(100);
        self.cx.setTheme(theme.widgetTheme(theme.currentName()));
        // Mount-time transitions read the published frame clock. Publish this
        // Cx's clock before mounting, rather than inheriting a previous test's.
        self.cx.layout();
        _ = self.cx.render();
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try mod.View.mount(self.cx, self.scope, .{ .context = self, .decision = decision, .defer_conflict = pause });
        try self.view.show(source());
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn decision(raw: *anyopaque, request: Conflict.Request) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.reject) return error.PermissionDenied;
        self.decisions += 1;
        self.last = request;
        if (request == .select) {
            const name = request.select.selection.rename;
            @memcpy(self.name[0..name.len], name);
            self.last.?.select.selection.rename = self.name[0..name.len];
        }
    }
    fn pause(raw: *anyopaque, key: domain.Key) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.pauses += 1;
        self.paused = key;
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(100) catch unreachable;
        for (0..4) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        const rect = node.globalRect();
        self.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        self.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        self.settle();
    }
};

test "transfer conflict view has exact default geometry and no automatic selection or decision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expect(f.view.isVisible());
    try std.testing.expect(f.view.selected.peek() == null);
    try std.testing.expect(f.view.primary_disabled.peek());
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), f.view.primary.getOpacity(), 0.001);
    try std.testing.expectEqual(theme.current().accent, f.view.primary.getBackground());
    const primary_label = findText(f.view.primary, "应用选择").?.getText().?;
    try std.testing.expectEqual(@as(f32, 12), primary_label.font_size);
    try std.testing.expectEqual(@as(u16, 500), primary_label.font_weight);
    try std.testing.expectApproxEqAbs(@as(f32, 620), f.view.dialog.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 381), f.view.dialog.globalRect().h, 0.1);
    const grip = f.view.grip.globalRect();
    const panel = f.view.dialog.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 32), grip.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 3), grip.h, 0.1);
    try std.testing.expectApproxEqAbs(panel.x + 294, grip.x, 0.1);
    try std.testing.expectApproxEqAbs(panel.y + 7, grip.y, 0.1);
    for (f.view.rows) |row| {
        try std.testing.expectApproxEqAbs(@as(f32, 596), row.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 34), row.globalRect().h, 0.1);
        try std.testing.expect(!row.behavior.interaction.a11y.?.checked.?);
    }
    f.click(f.view.primary);
    try std.testing.expectEqual(@as(usize, 0), f.decisions);
    try std.testing.expectEqual(@as(usize, 0), f.pauses);
}

test "transfer conflict view keeps rename draft across four choices and same key polling then sends exact request once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.rows[1]);
    try std.testing.expect(f.view.primary_disabled.peek());
    f.cx.setFocus(f.view.input.input_container);
    f.cx.handleTextInput("release-v2.tar.gz");
    f.settle();
    try std.testing.expect(!f.view.primary_disabled.peek());
    try std.testing.expectApproxEqAbs(@as(f32, 1), f.view.primary.getOpacity(), 0.001);
    f.click(f.view.rows[0]);
    f.click(f.view.rows[2]);
    f.click(f.view.rows[3]);
    f.click(f.view.rows[1]);
    try f.view.show(source());
    f.settle();
    try std.testing.expectEqualStrings("release-v2.tar.gz", f.view.rename.peek());
    try std.testing.expectEqualStrings("save_as", f.view.selected.peek().?);
    try std.testing.expectEqual(@as(usize, 0), f.decisions);
    f.click(f.view.checkbox);
    f.click(f.view.primary);
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expect(std.meta.eql(key_, f.last.?.key()));
    try std.testing.expectEqual(domain.Choice.save_as, f.last.?.select.selection.choice.?);
    try std.testing.expectEqualStrings("release-v2.tar.gz", f.last.?.select.selection.rename);
    try std.testing.expect(f.last.?.select.selection.apply_to_remaining);
    try f.view.show(source());
    f.click(f.view.primary);
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
}

fn findText(node: *ui.Node, text: []const u8) ?*ui.Node {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, text)) return node;
    for (node.children.items) |child| if (findText(child, text)) |found| return found;
    return null;
}

test "transfer conflict view pause and overwrite return carry original key ticket without cancelling" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.close);
    try std.testing.expectEqual(@as(usize, 1), f.pauses);
    try std.testing.expect(std.meta.eql(key_, f.paused.?));
    try std.testing.expect(!f.view.isVisible());
    const targets = [_]domain.OverwriteTarget{.{ .key = key_, .path = "/srv/releases/release.tar.gz", .version = target_version }};
    try f.view.show(confirmation(.upload, 23, &targets));
    f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, 460), f.view.dialog.globalRect().w, 0.1);
    f.click(f.view.back);
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(@as(u64, 23), f.last.?.return_to_choice.ticket.id);
    try std.testing.expect(std.meta.eql(key_, f.last.?.key()));
    try std.testing.expectEqual(@as(usize, 1), f.pauses);
}

test "transfer conflict view rejects old revisions and old pointer cannot approve a changed ticket" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var next = source();
    next.pending.choice.key.revision = 2;
    try f.view.show(next);
    try std.testing.expectError(error.StaleConflict, f.view.show(source()));
    const targets = [_]domain.OverwriteTarget{.{ .key = next.pending.choice.key, .path = "/srv/releases/release.tar.gz", .version = target_version }};
    try f.view.show(confirmation(.upload, 23, &targets));
    f.settle();
    const primary = f.view.primary.globalRect();
    f.cx.handleMouseDown(primary.x + primary.w / 2, primary.y + primary.h / 2, .{});
    try f.view.show(confirmation(.upload, 24, &targets));
    f.cx.handleMouseUp(primary.x + primary.w / 2, primary.y + primary.h / 2);
    f.settle();
    try std.testing.expectEqual(@as(usize, 0), f.decisions);
    f.click(f.view.primary);
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(@as(u64, 24), f.last.?.confirm_overwrite.ticket.id);
    try std.testing.expectEqual(@as(u64, 2), f.last.?.key().revision);
}

test "transfer conflict view local confirmation preserves exact geometry and long batch targets scroll above fixed actions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const targets = [_]domain.OverwriteTarget{.{ .key = key_, .path = "/local/release.tar.gz", .version = target_version }};
    try f.view.show(confirmation(.download, 33, &targets));
    f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, 480), f.view.dialog.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 199), f.view.dialog.globalRect().h, 0.1);
    var batch: [20]domain.OverwriteTarget = undefined;
    for (&batch, 0..) |*target, index| {
        target.* = targets[0];
        target.key.entry = @intCast(index);
        target.path = "/local/full-untruncated-directory-name/release-complete-target-name.tar.gz";
    }
    try f.view.show(confirmation(.download, 34, &batch));
    f.settle();
    try std.testing.expect(f.view.scroll.content.globalRect().h > f.view.scroll.container.globalRect().h);
    const footer = f.view.footer.globalRect();
    const button = f.view.primary.globalRect();
    try std.testing.expect(button.y >= footer.y and button.y + button.h <= footer.y + footer.h);
    try std.testing.expect(button.y + button.h <= 480);
    try std.testing.expect(std.mem.indexOf(u8, f.view.confirmation_paths.getText().?.content, batch[19].path) != null);
    f.cx.setFocus(f.view.back);
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(@as(u64, 34), f.last.?.return_to_choice.ticket.id);
    try std.testing.expectEqual(@as(usize, 0), f.pauses);
}

test "transfer conflict view initialization is independent of a previous Cx frame clock" {
    const previous = try ui.Cx.init(a, std.testing.io);
    previous.root = try ui.box(previous, .{ .width = .fill(), .height = .fill() }, .{});
    try previous.setTestFrameStep(100);
    for (0..3) |_| {
        previous.requestRedraw();
        previous.advanceFrameClock();
        previous.layout();
        _ = previous.render();
    }
    previous.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(theme.current().accent, f.view.primary.getBackground());
}
