//! Contract tests for the standalone AI workspace page shell.
const std = @import("std");
const ui = @import("ui");
const shell = @import("ai_workspace_shell.zig");

const Host = struct {
    new_chat: usize = 0,
    selected_conversation: []const u8 = "",
    selected_tab: shell.InspectorTab = .files,
    selected_file: []const u8 = "",
    inserted_file: []const u8 = "",
    toggled_left: ?bool = null,
    toggled_inspector: ?bool = null,
    closed_inspector: usize = 0,
    search: []const u8 = "",

    fn onNewChat(context: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.new_chat += 1;
    }
    fn onSelectConversation(context: ?*anyopaque, id: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.selected_conversation = id;
    }
    fn onToggleLeft(context: ?*anyopaque, collapsed: bool) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.toggled_left = collapsed;
    }
    fn onToggleInspector(context: ?*anyopaque, open: bool) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.toggled_inspector = open;
    }
    fn onSelectTab(context: ?*anyopaque, tab: shell.InspectorTab) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.selected_tab = tab;
    }
    fn onSelectFile(context: ?*anyopaque, path: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.selected_file = path;
    }
    fn onInsertFile(context: ?*anyopaque, path: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.inserted_file = path;
    }
    fn onCloseInspector(context: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.closed_inspector += 1;
    }
    fn onSearch(context: ?*anyopaque, value: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.search = value;
    }
};

fn newHost() Host {
    return .{};
}

fn click(cx: *ui.Cx, node: *ui.Node) void {
    const rect = node.globalRect();
    cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
}

const sample_sessions = [_]shell.Conversation{
    .{ .id = "c1", .title = "排查网关超时", .subtitle = "prod-web-01 · 5 分钟前", .selected = true },
    .{ .id = "c2", .title = "BMC 固件巡检", .subtitle = "机房 A · 昨天" },
};
const sample_files = [_]shell.FileRow{
    .{ .path = "src", .name = "src", .kind = .directory, .depth = 0, .expanded = true },
    .{ .path = "src/main.zig", .name = "main.zig", .depth = 1, .added = 12, .removed = 3 },
    .{ .path = "Dockerfile", .name = "Dockerfile", .depth = 0 },
};

fn mountShell(host: *Host, config: shell.Config) !*shell.View {
    var resolved = config;
    resolved.parent = resolved.cx.root.?;
    resolved.callbacks = .{
        .context = host,
        .new_chat = Host.onNewChat,
        .select_conversation = Host.onSelectConversation,
        .toggle_left_rail = Host.onToggleLeft,
        .toggle_inspector = Host.onToggleInspector,
        .select_inspector_tab = Host.onSelectTab,
        .select_file = Host.onSelectFile,
        .insert_file_reference = Host.onInsertFile,
        .close_inspector = Host.onCloseInspector,
        .search_changed = Host.onSearch,
    };
    return shell.mount(resolved);
}

test {
    _ = @import("ai_standalone_bridge.zig");
    _ = @import("../plugins/ai/view.zig");
}

test "mounts the three-column shell and routes every interaction through callbacks" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 800);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    var host = newHost();
    const view = try mountShell(&host, .{
        .cx = cx,
        .scope = scope,
        .title = "排查网关超时",
        .workspace_name = "ZeroWork",
        .sessions = &sample_sessions,
        .files = &sample_files,
        .preview = .{ .file_name = "main.zig", .path = "src/main.zig", .diff = "+const timeout = 30;\n-const timeout = 10;\n", .source = "const std = @import(\"std\");\n\npub fn main() void {}\n" },
    });

    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 220), view.left_rail.globalRect().w, 0.5);
    try std.testing.expectEqual(@as(usize, 2), view.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 3), view.files.items.len);
    try std.testing.expect(view.inspector_root.style.display == .none);
    try std.testing.expectEqualStrings("独立 AI · 读取选定会话", view.scope_badge_node.getText().?.content);

    click(cx, view.new_chat_button);
    try std.testing.expectEqual(@as(usize, 1), host.new_chat);

    view.search_value.set("BMC");
    shell.set_search_query(view, "BMC");
    cx.advanceFrameClock();
    _ = cx.render();
    cx.layout();
    try std.testing.expectEqualStrings("BMC", host.search);
    try std.testing.expectEqual(@as(usize, 1), view.session_list.children.items.len);
    shell.set_search_query(view, "");
    cx.advanceFrameClock();
    _ = cx.render();
    cx.layout();
    try std.testing.expectEqual(@as(usize, 2), view.session_list.children.items.len);

    click(cx, view.session_list.children.items[0]);
    try std.testing.expectEqualStrings("c1", host.selected_conversation);
    click(cx, view.session_list.children.items[1]);
    try std.testing.expectEqualStrings("c2", host.selected_conversation);
    try std.testing.expectEqualStrings("c1", view.selected_id.peek().?);

    shell.set_inspector_open(view, true);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 340), view.inspector_root.globalRect().w, 0.5);
    try std.testing.expect(view.center_slot.globalRect().w >= 360);
    const inspector_rect = view.inspector_root.globalRect();
    for (view.tab_buttons) |tab| {
        const rect = tab.globalRect();
        try std.testing.expect(rect.w > 0);
        try std.testing.expect(rect.x + rect.w <= inspector_rect.x + inspector_rect.w + 0.5);
    }
    const close_rect = view.close_button.globalRect();
    try std.testing.expect(close_rect.x + close_rect.w <= inspector_rect.x + inspector_rect.w + 0.5);
    try std.testing.expect(view.preview_box.globalRect().w > 0);

    click(cx, view.tab_buttons[1]);
    try std.testing.expectEqual(shell.InspectorTab.members, host.selected_tab);
    try std.testing.expect(view.tab_pages[1].style.display == .flex);
    try std.testing.expect(view.tab_pages[0].style.display == .none);

    shell.set_inspector_tab(view, .files);
    cx.layout();
    click(cx, view.file_list.children.items[1]);
    try std.testing.expectEqualStrings("src/main.zig", host.selected_file);

    click(cx, view.preview_mode_buttons[1]);
    try std.testing.expectEqual(shell.PreviewMode.source, view.preview_mode);
    click(cx, view.preview_mode_buttons[0]);
    try std.testing.expectEqual(shell.PreviewMode.diff, view.preview_mode);

    click(cx, view.inspector_toggle);
    try std.testing.expectEqual(false, host.toggled_inspector.?);
    shell.set_inspector_open(view, true);
    click(cx, view.close_button);
    try std.testing.expectEqual(@as(usize, 1), host.closed_inspector);

    click(cx, view.collapse_button);
    try std.testing.expectEqual(true, host.toggled_left.?);
    try std.testing.expect(view.left_rail.style.display == .none);
    try std.testing.expect(view.expand_button.style.display == .flex);
}

test "updates retained rows, preview content and header labels in place" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1180, 760);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    var host = newHost();
    const view = try mountShell(&host, .{ .cx = cx, .scope = scope });
    const first = [_]shell.Conversation{.{ .id = "a", .title = "第一轮", .subtitle = "刚刚", .selected = true }};
    try shell.set_sessions(view, &first);
    try std.testing.expectEqualStrings("a", view.selected_id.peek().?);
    const unchanged = view.session_list.children.items[0];
    try shell.set_sessions(view, &first);
    try std.testing.expectEqual(unchanged, view.session_list.children.items[0]);
    const old_id = @intFromPtr(view.selected_id.peek().?.ptr);
    try shell.set_sessions(view, &.{.{ .id = "a", .title = "更新标题", .selected = true }});
    try std.testing.expectEqualStrings("a", view.selected_id.peek().?);
    try std.testing.expect(old_id != @intFromPtr(view.selected_id.peek().?.ptr));
    const second = [_]shell.Conversation{
        .{ .id = "b", .title = "第二轮", .subtitle = "刚刚" },
        .{ .id = "c", .title = "第三轮", .subtitle = "昨天" },
    };
    try shell.set_sessions(view, &second);
    try std.testing.expectEqual(@as(usize, 2), view.sessions.items.len);
    cx.layout();

    const files = [_]shell.FileRow{
        .{ .path = "README.md", .name = "README.md", .selected = true },
        .{ .path = "build.zig", .name = "build.zig" },
    };
    try shell.set_files(view, &files);
    try std.testing.expectEqualStrings("README.md", view.selected_file.peek().?);
    try std.testing.expectEqual(@as(usize, 2), view.files.items.len);
    const old_file = @intFromPtr(view.selected_file.peek().?.ptr);
    try shell.set_files(view, &files);
    try std.testing.expectEqualStrings("README.md", view.selected_file.peek().?);
    try std.testing.expect(old_file != @intFromPtr(view.selected_file.peek().?.ptr));

    try shell.set_file_preview(view, "build.zig", "build.zig", "+one\n-two\n", "const std = @import(\"std\");\n\npub fn main() void {}\n");
    try std.testing.expectEqualStrings("build.zig", view.preview_name);
    shell.set_inspector_open(view, true);
    shell.set_inspector_tab(view, .files);
    shell.set_preview_mode(view, .source);
    try std.testing.expect(view.preview_gutter.style.display == .flex);
    try std.testing.expectEqual(ui.TextWrap.newline_only, view.preview_code.getText().?.wrap);
    try std.testing.expectEqual(ui.TextWrap.newline_only, view.preview_gutter.getText().?.wrap);
    cx.advanceFrameClock();
    _ = cx.render();
    cx.layout();
    const code_layout = view.preview_code.getLayoutOutput().artifacts.text_layout orelse return error.MissingTextLayout;
    try std.testing.expect(code_layout.line_count >= 3);
    const gutter_layout = view.preview_gutter.getLayoutOutput().artifacts.text_layout orelse return error.MissingTextLayout;
    try std.testing.expect(gutter_layout.line_count >= 3);
    shell.set_preview_mode(view, .diff);
    try std.testing.expect(view.preview_gutter.style.display == .none);

    try shell.set_title(view, "新的对话标题");
    try shell.set_scope_badge(view, "独立 AI · 全局只读");
    try shell.set_workspace_name(view, "另一个工作区");
    try std.testing.expectEqualStrings("新的对话标题", view.title_node.getText().?.content);
    try std.testing.expectEqualStrings("独立 AI · 全局只读", view.scope_badge_node.getText().?.content);
    try std.testing.expectEqualStrings("另一个工作区", view.workspace_name_node.getText().?.content);
    try shell.set_file_preview(view, "", "", "", "");
    try std.testing.expect(view.preview_placeholder.style.display == .flex);
}

test "workspace image preview releases textures on replacement failure revoke and teardown" {
    const Probe = struct {
        created: u32 = 0,
        released: u32 = 0,
        fail_upload: bool = false,
        fn create(raw: *anyopaque, width: u32, height: u32) !u32 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(width == 2 and height == 1);
            self.created += 1;
            return self.created;
        }
        fn update(raw: *anyopaque, _: u32, rgba: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(usize, 8), rgba.len);
            if (self.fail_upload) return error.TextureUploadFailed;
        }
        fn release(raw: *anyopaque, id: u32) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(id != 0 and id <= self.created);
            self.released += 1;
        }
    };
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1180, 760);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var probe: Probe = .{};
    var host = newHost();
    {
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        const view = try mountShell(&host, .{ .cx = cx, .scope = scope, .preview_texture_backend = .{ .context = &probe, .create = Probe.create, .update = Probe.update, .release = Probe.release } });
        const pixels = &[_]u8{ 255, 0, 0, 255, 255, 0, 0, 255 };
        try shell.set_image_preview(view, "a.png", 2, 1, pixels);
        try std.testing.expect(view.preview_image_frame.style.display == .flex and view.preview_texture == 1);
        try shell.set_file_preview(view, "a.md", "a.md", "", "disk text");
        try std.testing.expect(view.preview_texture == null and view.preview_image_frame.style.display == .none);
        try std.testing.expectEqual(@as(u32, 1), probe.released);
        probe.fail_upload = true;
        try std.testing.expectError(error.TextureUploadFailed, shell.set_image_preview(view, "b.png", 2, 1, pixels));
        try std.testing.expectEqual(@as(u32, 2), probe.released);
        probe.fail_upload = false;
        try shell.set_image_preview(view, "b.png", 2, 1, pixels);
        try shell.bind_files(view, null, false);
        try std.testing.expect(view.preview_texture == null and view.preview_image_frame.style.display == .none);
        try std.testing.expectEqual(@as(u32, 3), probe.released);
        try shell.bind_files(view, "project", true);
        try shell.set_image_preview(view, "c.png", 2, 1, pixels);
    }
    try std.testing.expectEqual(probe.created, probe.released);
    try std.testing.expectEqual(@as(u32, 4), probe.created);
}

test "compact width collapses rails without changing the center minimum" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(720, 700);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var host = newHost();
    const view = try mountShell(&host, .{ .cx = cx, .scope = scope, .inspector_open = true });
    cx.advanceFrameClock();
    _ = cx.render();
    cx.advanceFrameClock();
    _ = cx.render();
    try std.testing.expect(view.left_collapsed);
    try std.testing.expect(!view.inspector_open);
    try std.testing.expect(view.center_slot.globalRect().w >= 360);
}

test "inspector hosts mount real pages and survive tab switches" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 800);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    var host = newHost();
    const view = try mountShell(&host, .{ .cx = cx, .scope = scope, .inspector_open = true });
    shell.set_inspector_tab(view, .members);
    cx.layout();

    const members_page = shell.inspector_page(view, .members);
    try std.testing.expect(members_page == view.tab_pages[1]);
    const empty = members_page.children.items[0];
    try std.testing.expect(empty.style.display == .flex);

    const members_host = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    members_host.meta.ownership.meta.test_id = "ai.workspace.test.members.host";
    try members_host.appendChild(cx.allocator, try ui.text(cx, "成员 A", .{}));
    try members_page.appendChild(cx.allocator, members_host);
    try shell.set_inspector_host(view, .members, members_host);

    try std.testing.expect(empty.style.display == .none);
    try std.testing.expect(members_host.style.display == .flex);
    try std.testing.expect(members_host.parent == members_page);
    try std.testing.expect(members_page.style.display == .flex);
    cx.layout();
    try std.testing.expect(members_host.globalRect().w > 0);
    try std.testing.expect(members_host.globalRect().h > 0);

    const graph_page = shell.inspector_page(view, .graph);
    const graph_host = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    try shell.set_inspector_host(view, .graph, graph_host);
    try std.testing.expect(graph_host.parent == graph_page);

    shell.set_inspector_tab(view, .board);
    try std.testing.expect(members_page.style.display == .none);
    try std.testing.expect(members_host.parent == members_page);
    try std.testing.expect(graph_host.parent == graph_page);

    shell.set_inspector_tab(view, .members);
    try std.testing.expect(members_page.style.display == .flex);
    try std.testing.expect(members_host.parent == members_page);
    try std.testing.expect(view.inspector_hosts[1] == members_host);
    try std.testing.expect(view.inspector_hosts[3] == graph_host);

    try shell.set_inspector_host(view, .members, null);
    try std.testing.expect(members_host.parent == null);
    try std.testing.expect(empty.style.display == .flex);
    try std.testing.expect(members_page.style.display == .flex);
    try std.testing.expect(view.inspector_hosts[1] == null);

    const replacement = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    try shell.set_inspector_host(view, .members, replacement);
    try std.testing.expect(replacement.parent == members_page);
    try std.testing.expect(empty.style.display == .none);
    try shell.set_inspector_host(view, .members, null);
    try std.testing.expect(replacement.parent == null);

    if (members_host.parent == null) cx.destroyDetached(members_host);
    if (replacement.parent == null) cx.destroyDetached(replacement);
}

test "an unavailable file browser does not render actionable preview controls" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 800);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var host = newHost();
    const view = try mountShell(&host, .{ .cx = cx, .scope = scope, .inspector_open = true, .files_unavailable_reason = "此页面未接入文件浏览。" });
    cx.layout();
    try std.testing.expect(view.file_scroll.container.style.display == .none);
    try std.testing.expect(view.preview_box.style.display == .none);
    try shell.set_files(view, &sample_files);
    try shell.set_file_preview(view, "ignored", "outside", "", "not displayed");
    try std.testing.expectEqual(@as(usize, 0), view.files.items.len);
    try std.testing.expectEqualStrings("", view.preview_source);
    const unavailable = view.files_page.children.items[2];
    try std.testing.expectEqualStrings("ai.workspace.files.unavailable", unavailable.meta.ownership.meta.test_id.?);
    try std.testing.expect(unavailable.globalRect().h > 0);
    shell.set_inspector_tab(view, .members);
    try std.testing.expect(shell.inspector_page(view, .members).style.display == .flex);
    try std.testing.expectEqual(shell.InspectorTab.files, host.selected_tab); // programmatic tab updates are not user actions
}
