const std = @import("std");
const ui = @import("ui");
const config = @import("config/config.zig");
const defaults = @import("config/transfer_defaults.zig");
const panel_view = @import("ui/transfer_panel.zig");
const transfer = @import("transfer/manager.zig");
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");

const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 9 };

test "settings transfer defaults freeze saved flags without changing the original transfer intent" {
    const policy: config.Transfer = .{ .verify_md5 = true, .@"resume" = false, .download_dir = "/unapproved/settings/default" };
    for ([_]panel_view.Data.Mode{ .upload, .download }) |mode| {
        const original: panel_view.Data = .{
            .mode = mode,
            .owner = owner,
            .endpoint = "root@original-host:22",
            .host_name = "Original host",
            .presentation = .drop,
            .sources = &.{"/source/original.bin"},
            .remote_dir = "/remote/original",
            .local_dir = "/local/selected",
            .link_text = "frozen route",
            .edit_remote_source = true,
            .require_directory_selection = true,
            .notify_complete = false,
        };
        const actual = defaults.confirmation(policy, original);
        var expected = original;
        expected.md5 = true;
        expected.resume_transfer = false;
        try std.testing.expect(std.meta.eql(expected, actual));
        const spec = try panel_view.buildSpec(actual);
        try std.testing.expect(spec.md5_check);
        try std.testing.expect(!spec.resume_transfer);
        try std.testing.expectEqual(@as(u64, 42), spec.session_id);
        try std.testing.expectEqualStrings("/local/selected", spec.local_dir);
    }
}

const Capture = struct {
    calls: usize = 0,
    submitted_owner: ?identity.SessionHandle = null,
    md5: bool = false,
    resume_transfer: bool = false,
    local_directory: [512]u8 = undefined,
    local_directory_len: usize = 0,
    fn submit(raw: *anyopaque, captured: identity.SessionHandle, spec: transfer.JobSpec) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.submitted_owner = captured;
        self.md5 = spec.md5_check;
        self.resume_transfer = spec.resume_transfer;
        self.local_directory_len = @min(spec.local_dir.len, self.local_directory.len);
        @memcpy(self.local_directory[0..self.local_directory_len], spec.local_dir[0..self.local_directory_len]);
    }
};

const Harness = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    panel: *panel_view.Panel,
    fn init(capture: *Capture) !Harness {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(1000, 800);
        cx.setTheme(theme.widgetTheme(theme.currentName()));
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        const panel = try std.testing.allocator.create(panel_view.Panel);
        errdefer std.testing.allocator.destroy(panel);
        panel.* = .{};
        cx.owner.enterMount();
        const anchor = panel.mount(cx, scope) catch |err| {
            cx.owner.exitMount();
            return err;
        };
        cx.owner.exitMount();
        try cx.root.?.appendChild(cx.allocator, anchor);
        panel.submit_ctx = capture;
        panel.on_submit_frozen = Capture.submit;
        return .{ .cx = cx, .scope = scope, .panel = panel };
    }
    fn deinit(self: Harness) void {
        self.scope.dispose();
        std.testing.allocator.destroy(self.panel);
        self.cx.deinit();
    }
    fn frames(self: Harness) void {
        for (0..5) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn click(self: Harness, node: *ui.Node) void {
        const rect = node.globalRect();
        self.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        self.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    }
};

test "settings transfer defaults actual Cx keeps user choices through config changes and retheme" {
    const original_theme = theme.currentName();
    defer theme.select(original_theme);
    theme.select(.dark);
    var capture: Capture = .{};
    const h = try Harness.init(&capture);
    defer h.deinit();
    var policy: config.Transfer = .{ .verify_md5 = true, .@"resume" = false };
    h.panel.show(defaults.confirmation(policy, .{
        .mode = .upload,
        .owner = owner,
        .sources = &.{"/tmp/source"},
        .remote_dir = "/remote/destination",
    }));
    h.frames();
    try std.testing.expect(h.panel.md5);
    try std.testing.expect(!h.panel.resume_transfer);
    const content = h.panel.viewport.?.content;
    const options = content.children.items[content.children.items.len - 1];
    h.click(options.children.items[0]);
    h.click(options.children.items[1]);
    try std.testing.expect(h.panel.resume_transfer);
    try std.testing.expect(!h.panel.md5);
    policy = .{ .verify_md5 = true, .@"resume" = false };
    theme.select(.light);
    h.cx.setTheme(theme.widgetTheme(theme.currentName()));
    h.panel.retheme();
    h.frames();
    // Only a newly opened intent consumes the saved policy. This open panel
    // keeps the actual pointer selections and submits those same values.
    try std.testing.expect(policy.verify_md5 != h.panel.md5);
    try std.testing.expect(policy.@"resume" != h.panel.resume_transfer);
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(owner, capture.submitted_owner.?);
    try std.testing.expect(!capture.md5);
    try std.testing.expect(capture.resume_transfer);
    h.panel.show(defaults.confirmation(policy, .{ .mode = .upload, .owner = owner, .sources = &.{"/tmp/new"}, .remote_dir = "/remote/new" }));
    h.frames();
    try std.testing.expect(h.panel.md5);
    try std.testing.expect(!h.panel.resume_transfer);
}

test "settings transfer defaults do not authorize a download directory without the original picker receipt" {
    var capture: Capture = .{};
    const h = try Harness.init(&capture);
    defer h.deinit();
    const path = try defaults.downloadDirectory(std.testing.allocator, "~/Downloads/测试 文件", "/Users/tester");
    var path_live = true;
    defer if (path_live) std.testing.allocator.free(path);
    h.panel.show(defaults.confirmation(.{ .verify_md5 = true }, .{
        .mode = .download,
        .owner = owner,
        .sources = &.{"/remote/source"},
        .local_dir = path,
        .require_directory_selection = true,
    }));
    // Panel.show must own the suggestion before the temporary expansion is released.
    @memset(path, 'x');
    std.testing.allocator.free(path);
    path_live = false;
    h.frames();
    try std.testing.expect(h.panel.md5);
    try std.testing.expectEqualStrings("/Users/tester/Downloads/测试 文件", h.panel.local_dir_sig.peek());
    try std.testing.expectEqualStrings("", h.panel.directory_selection.peek());
    try std.testing.expect(h.panel.disabled.peek());
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    const ticket = try h.panel.directoryTicket();
    // Cancelling the system picker produces no receipt and leaves the suggestion inert.
    h.panel.retheme();
    h.frames();
    try std.testing.expectEqualStrings("/Users/tester/Downloads/测试 文件", h.panel.local_dir_sig.peek());
    try std.testing.expect(h.panel.disabled.peek());
    try std.testing.expectEqualStrings("", h.panel.directory_selection.peek());
    try h.panel.applyDirectorySelection(ticket, "/tmp/selected-by-picker");
    h.frames();
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(owner, capture.submitted_owner.?);
    try std.testing.expect(capture.md5);
    try std.testing.expectEqualStrings("/tmp/selected-by-picker", capture.local_directory[0..capture.local_directory_len]);

    // Reopening is a new intent: even the same directory needs its own picker receipt.
    h.panel.show(.{ .mode = .download, .owner = owner, .sources = &.{"/remote/source"}, .local_dir = "/tmp/selected-by-picker", .require_directory_selection = true });
    h.frames();
    try std.testing.expect(h.panel.disabled.peek());
    try std.testing.expectEqualStrings("", h.panel.directory_selection.peek());
    h.panel.handleSubmit();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "settings transfer defaults expand only the current home or absolute download directories" {
    const cases = [_]struct { configured: []const u8, home: ?[]const u8, expected: []const u8 }{
        .{ .configured = "~/Downloads/测试 文件", .home = "/Users/tester", .expected = "/Users/tester/Downloads/测试 文件" },
        .{ .configured = "~/Downloads", .home = "/", .expected = "/Downloads" },
        .{ .configured = "~", .home = "/Users/tester", .expected = "/Users/tester" },
        .{ .configured = "~/", .home = "/Users/tester", .expected = "/Users/tester" },
        .{ .configured = "/Volumes/Test Disk/Downloads", .home = null, .expected = "/Volumes/Test Disk/Downloads" },
        .{ .configured = "", .home = null, .expected = "" },
    };
    for (cases) |case| {
        const actual = try defaults.downloadDirectory(std.testing.allocator, case.configured, case.home);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
    for ([_][]const u8{ "relative/path", "~someone/Downloads", "/tmp/has\x00suffix", "/tmp/line\nbreak", "/tmp/\xff" }) |invalid| {
        try std.testing.expectError(error.InvalidDownloadDirectory, defaults.downloadDirectory(std.testing.allocator, invalid, "/Users/tester"));
    }
    try std.testing.expectError(error.MissingHomeDirectory, defaults.downloadDirectory(std.testing.allocator, "~/Downloads", null));
    try std.testing.expectError(error.InvalidDownloadDirectory, defaults.downloadDirectory(std.testing.allocator, "~/Downloads", "relative/home"));
}
