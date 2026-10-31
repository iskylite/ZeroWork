const std = @import("std");
const ui = @import("ui");
const view = @import("config/settings_content_view.zig");
const Controller = @import("config/settings_controller.zig").Controller;
const schema = @import("config/settings_schema.zig");
const a = std.testing.allocator;

fn changed(_: *anyopaque) void {}
fn request(_: *anyopaque, _: view.Key, _: *ui.Node) void {}
fn action(_: *anyopaque, _: view.Action) void {}
fn byId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (byId(child, id)) |found| return found;
    return null;
}

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    controller: Controller,
    fn init() !Fixture {
        const cx = try ui.Cx.init(a, std.testing.io);
        errdefer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        errdefer scope.dispose();
        cx.setViewport(636, 700);
        cx.root = try ui.box(cx, .{ .width = .{ .px = 636 }, .height = .{ .px = 700 } }, .{});
        var initial: @import("config/config.zig").Config = .{};
        initial.ui.materials.background.enabled = true;
        initial.ui.materials.background.path = "/fixture/search-background.png";
        return .{ .cx = cx, .scope = scope, .controller = try Controller.init(a, initial) };
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        self.controller.deinit();
    }
    fn mount(self: *Fixture) !view.Mounted {
        const mounted = try view.mountPage(self.cx, self.scope, &self.controller, .{ .context = self, .changed = changed, .request_edit = request, .action = action });
        try self.cx.root.?.appendChild(a, mounted.root);
        self.cx.layout();
        return mounted;
    }
};

test "settings search schema aliases mount their actual appearance section and control" {
    const Case = struct { query: []const u8, section: []const u8, control: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .query = "theme", .section = "themes", .control = "settings.theme.current" },
        .{ .query = "font_family", .section = "font", .control = "settings.field.font_family" },
        .{ .query = "font_size", .section = "font", .control = "settings.field.font_size" },
        .{ .query = "font_weight", .section = "font", .control = "settings.field.font_weight" },
        .{ .query = "line_height", .section = "font", .control = "settings.field.line_height" },
        .{ .query = "cursor_style", .section = "font", .control = "settings.field.cursor_style" },
        .{ .query = "sidebar_collapsed", .section = "aids", .control = "settings.toggle.sidebar_collapsed" },
        .{ .query = "timestamp_gutter", .section = "aids", .control = "settings.toggle.timestamp_gutter" },
        .{ .query = "command_info", .section = "aids", .control = "settings.toggle.command_info" },
        .{ .query = "input_line_highlight", .section = "aids", .control = "settings.toggle.input_line_highlight" },
        .{ .query = "enabled", .section = "aids", .control = "settings.toggle.enabled" },
        .{ .query = "blur_px", .section = "materials", .control = "settings.field.blur_px" },
        .{ .query = "path", .section = "materials", .control = "settings.background.filename" },
        .{ .query = "transparency", .section = "materials", .control = "settings.field.transparency" },
        .{ .query = "fit", .section = "materials", .control = "settings.field.fit" },
        .{ .query = "alignment_x", .section = "materials", .control = "settings.field.alignment" },
        .{ .query = "alignment_y", .section = "materials", .control = "settings.field.alignment" },
    };
    for (cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        f.controller.model.selectPage(2);
        try f.controller.setSearch(case.query);
        try std.testing.expectEqual(@as(usize, 2), f.controller.model.page_index);
        const mounted = try f.mount();
        var buffer: [80]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "settings.appearance.{s}", .{case.section});
        const section = byId(mounted.root, id);
        if (section == null) std.debug.print("missing appearance section for schema alias {s}\n", .{case.query});
        try std.testing.expect(section != null);
        try std.testing.expect(section.?.globalRect().h > 0);
        if (case.control) |control| {
            if (byId(section.?, control) == null) std.debug.print("missing control {s} for alias {s}\n", .{ control, case.query });
            try std.testing.expect(byId(section.?, control) != null);
        }
    }
}

test "settings search aliases preserve invalid raw draft and original category on clear" {
    var f = try Fixture.init();
    defer f.deinit();
    f.controller.model.selectPage(3);
    try std.testing.expectError(error.OutOfRange, f.controller.editRaw("ui", "font_size", "97"));
    const folds = f.controller.folded_sections;
    try f.controller.setSearch("font_size");
    const mounted = try f.mount();
    const field = byId(mounted.root, "settings.field.font_size");
    try std.testing.expect(field != null);
    try std.testing.expect(byId(mounted.root, "settings.field.font_family") == null);
    try std.testing.expect(byId(mounted.root, "settings.field.font_weight") == null);
    try std.testing.expect(byId(mounted.root, "settings.field.line_height") == null);
    try std.testing.expect(byId(mounted.root, "settings.field.cursor_style") != null);
    try std.testing.expect(byId(mounted.root, "settings.font.preview") != null);
    const raw = f.controller.raw_fields[schema.find("ui", "font_size").?];
    try std.testing.expectEqualStrings("97", raw.input.?);
    try std.testing.expect(raw.problem != null);
    try std.testing.expect(!f.controller.canSave());
    try f.controller.setSearch("");
    try std.testing.expectEqual(@as(usize, 3), f.controller.model.page_index);
    try std.testing.expectEqual(folds, f.controller.folded_sections);
    try std.testing.expectEqualStrings("97", f.controller.raw_fields[schema.find("ui", "font_size").?].input.?);
}

test "settings search every scalar schema key keeps its own category and mounts its control" {
    const pages = @import("config/settings_pages.zig").pages;
    for (schema.fields) |entry| {
        var f = try Fixture.init();
        defer f.deinit();
        const expected_page = for (pages, 0..) |page, index| {
            if (std.mem.eql(u8, entry.page, page.name)) break index;
        } else unreachable;
        f.controller.model.selectPage(expected_page);
        try f.controller.setSearch(entry.key);
        try std.testing.expectEqual(expected_page, f.controller.model.page_index);
        const mounted = try f.mount();
        var buffer: [96]u8 = undefined;
        const id = if (expected_page == 0) blk: {
            if (std.mem.eql(u8, entry.key, "theme")) break :blk "settings.theme.current";
            if (std.mem.eql(u8, entry.key, "path")) break :blk "settings.background.filename";
            if (std.mem.eql(u8, entry.key, "alignment_x") or std.mem.eql(u8, entry.key, "alignment_y")) break :blk "settings.field.alignment";
            const boolean = @import("config/settings_values.zig").read(f.controller.model.value, entry.section, entry.key).? == .boolean;
            break :blk try std.fmt.bufPrint(&buffer, "settings.{s}.{s}", .{ if (boolean) "toggle" else "field", entry.key });
        } else if (std.mem.eql(u8, entry.section, "ai") and std.mem.eql(u8, entry.key, "default_provider")) "settings.ai.behavior" else try std.fmt.bufPrint(&buffer, "settings.field.{s}", .{entry.key});
        if (byId(mounted.root, id) == null) std.debug.print("missing scalar search control {s}.{s} ({s})\n", .{ entry.section, entry.key, id });
        try std.testing.expect(byId(mounted.root, id) != null);
    }
}
