//! Actual Windows OLE receiver fixture; driven by an external native process.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const State = struct {
    app: *App,
    status: *ui.Node,
    hash: *ui.Node,
    target: *ui.Node,
    source_status: *ui.Node,
    source_token: u64 = 0,
    preview: bool = false,
    source_mode: enum { text, file, url, internal, uri } = .text,
    source_operations: u8 = 1,
    source_file: []const u8,
    enters: u32 = 0,
    leaves: u32 = 0,
    drops: u32 = 0,
    policy: u8 = 1,
    fn report(self: *@This(), phase: []const u8, payload: ?ui.HandlerRef.DropPayload) void {
        const text = std.json.Stringify.valueAlloc(self.app.cx.allocator, .{
            .phase = phase,
            .enters = self.enters,
            .leaves = self.leaves,
            .drops = self.drops,
            .policy = self.policy,
            .length = if (payload) |p| p.paths.len else @as(usize, 0),
            .kind = if (payload) |p| p.payload_kind else @as(u8, 0),
            .truncated = if (payload) |p| p.payload_truncated else false,
            .untrusted = if (payload) |p| p.payload_is_untrusted else true,
            .x = if (payload) |p| p.x else @as(f32, 0),
            .y = if (payload) |p| p.y else @as(f32, 0),
        }, .{}) catch @panic("drop report allocation");
        if (payload) |p| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(p.paths, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            const owned = self.app.cx.allocator.dupe(u8, &hex) catch @panic("drop hash allocation");
            self.hash.setText(.{ .content = owned, .font_size = 12, .color = ui.Color.WHITE });
        }
        self.status.setText(.{ .content = text, .font_size = 12, .color = ui.Color.WHITE });
    }
    pub fn enter(self: *@This()) void {
        self.enters += 1;
        self.report("enter", null);
    }
    pub fn leave(self: *@This()) void {
        self.leaves += 1;
        self.report("leave", null);
    }
    pub fn drop(self: *@This(), p: ui.HandlerRef.DropPayload) void {
        self.drops += 1;
        self.report("drop", p);
    }
    fn set(self: *@This(), mask: u8) void {
        self.app.sdk.setDragTargetOperations(self.app.win.getWindowId(), @bitCast(mask)) catch @panic("native target policy");
        self.policy = mask;
        self.report("policy", null);
    }
    pub fn copy(self: *@This()) void {
        self.set(1);
    }
    pub fn move(self: *@This()) void {
        self.set(2);
    }
    pub fn link(self: *@This()) void {
        self.set(4);
    }
    pub fn none(self: *@This()) void {
        self.set(0);
    }
    pub fn previewToggle(self: *@This()) void {
        self.preview = !self.preview;
    }
    pub fn cancelSource(self: *@This()) void {
        self.app.win.cancelDrag();
    }
    pub fn sourceText(self: *@This()) void {
        self.source_mode = .text;
    }
    pub fn sourceFile(self: *@This()) void {
        self.source_mode = .file;
    }
    pub fn sourceUrl(self: *@This()) void {
        self.source_mode = .url;
    }
    pub fn sourceInternal(self: *@This()) void {
        self.source_mode = .internal;
    }
    pub fn sourceUri(self: *@This()) void {
        self.source_mode = .uri;
    }
    pub fn sourceAll(self: *@This()) void {
        self.source_operations = 7;
    }
    pub fn sourceCopy(self: *@This()) void {
        self.source_operations = 1;
    }
    fn sourceReport(self: *@This(), phase: []const u8, token: u64, operation: u8, untrusted: bool) void {
        const text = std.json.Stringify.valueAlloc(self.app.cx.allocator, .{ .phase = phase, .token = token, .operation = operation, .untrusted = untrusted, .preview = self.preview, .mode = @tagName(self.source_mode), .allowed = self.source_operations }, .{}) catch @panic("source status");
        self.source_status.setText(.{ .content = text, .font_size = 12, .color = ui.Color.WHITE });
    }
    fn sourceEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *@This() = @ptrCast(@alignCast(context orelse return .ignored));
        if (event != .mouse_down or event.mouse_down.button != .left) return .ignored;
        std.debug.print("[windows-source-fixture] down preview={}\n", .{self.preview});
        const uri = std.fmt.allocPrint(self.app.cx.allocator, "file:///{s}", .{self.source_file}) catch @panic("source URI");
        defer self.app.cx.allocator.free(uri);
        for (uri) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        const borrowed = self.app.cx.allocator.dupe(u8, switch (self.source_mode) {
            .text => "source 中文 🧪",
            .file => self.source_file,
            .url => "https://zenit.example/路径?q=🧪",
            .internal => "内部\x00🧪payload",
            .uri => uri,
        }) catch @panic("source payload");
        defer self.app.cx.allocator.free(borrowed);
        const png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 6, 0, 0, 0, 114, 182, 13, 36, 0, 0, 0, 23, 73, 68, 65, 84, 120, 156, 99, 56, 145, 98, 212, 192, 37, 34, 247, 159, 1, 4, 52, 2, 42, 28, 0, 44, 250, 4, 74, 75, 130, 15, 60, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
        const token = self.app.sdk.beginDrag(self.app.win.getWindowId(), .{ .payload_kind = switch (self.source_mode) {
            .file, .url, .uri => .file_url,
            .internal => .internal,
            .text => .text,
        }, .payload = borrowed, .allowed_operations = @bitCast(self.source_operations), .preview_png = if (self.preview) &png else "", .preview_width = 80, .preview_height = 40, .hotspot_x = 4, .hotspot_y = 4 }) catch {
            self.sourceReport("refused", 0, 0, false);
            return .stop;
        };
        @memset(borrowed, 'x'); // Start must snapshot this before returning.
        self.source_token = token;
        self.sourceReport("active", token, 0, false);
        self.app.cx.cancelPointerInteractions(.native_handoff);
        return .stop;
    }
    fn sourceFrame(node: *ui.Node) void {
        const self: *@This() = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
        if (self.source_token == 0) return;
        for (self.app.sdk.events()) |event| {
            if (event == .drag and event.drag.kind == 4 and event.drag.source_token == self.source_token) {
                self.sourceReport("complete", event.drag.source_token, event.drag.operation, event.drag.payload_is_untrusted);
                self.source_token = 0;
                break;
            }
        }
    }
};
pub fn mount(app: *App, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 440 }, .direction = .column, .gap = 8 }, .{});
    const exe_dir = try std.process.executableDirPathAlloc(cx.io, cx.allocator);
    defer cx.allocator.free(exe_dir);
    const directory = try std.fmt.allocPrint(cx.allocator, "{s}\\drop-fixtures", .{exe_dir});
    try std.Io.Dir.cwd().createDirPath(cx.io, directory);
    inline for (.{ "输入-🧪.txt", "另一个文件.txt" }) |name| {
        const path = try std.fmt.allocPrint(cx.allocator, "{s}\\{s}", .{ directory, name });
        defer cx.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(cx.io, path, .{});
        defer file.close(cx.io);
        try file.writeStreamingAll(cx.io, "Zenit external OLE drop fixture\n");
    }
    const path_label = try ui.text(cx, directory, .{ .font_size = 12, .color = ui.Color.WHITE });
    path_label.meta.ownership.meta.test_id = "drop.directory";
    try root.appendChild(cx.allocator, path_label);
    const status = try ui.text(cx, "ready", .{ .font_size = 12, .color = ui.Color.WHITE });
    status.meta.ownership.meta.test_id = "drop.status";
    const hash = try ui.text(cx, "", .{ .font_size = 12, .color = ui.Color.WHITE });
    hash.meta.ownership.meta.test_id = "drop.hash";
    const target = try ui.box(cx, .{ .width = .{ .px = 360 }, .height = .{ .px = 100 }, .background = ui.Color{ .r = 60, .g = 100, .b = 140, .a = 255 } }, .{});
    target.meta.ownership.meta.test_id = "drop.target";
    const source_status = try ui.text(cx, "ready", .{ .font_size = 12, .color = ui.Color.WHITE });
    source_status.meta.ownership.meta.test_id = "drop.source-status";
    const state = try cx.bindState(State, .{ .app = app, .status = status, .hash = hash, .target = target, .source_status = source_status, .source_file = try std.fmt.allocPrint(cx.allocator, "{s}\\输入-🧪.txt", .{directory}) });
    root.behavior.events.event_context = state;
    root.addBeforeRender(State.sourceFrame);
    target.behavior.events.on_drag_enter = cx.on(State, state, State.enter);
    target.behavior.events.on_drag_leave = cx.on(State, state, State.leave);
    target.behavior.events.on_drop = ui.Cx.dropHandlerFrom(State, state, State.drop);
    const label = try ui.text(cx, "External OLE drop target", .{ .font_size = 18, .color = ui.Color.WHITE });
    try target.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, target);
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 40 }, .direction = .row, .gap = 8 }, .{});
    inline for (.{ .{ "drop.copy", "Copy", State.copy }, .{ "drop.move", "Move", State.move }, .{ "drop.link", "Link", State.link }, .{ "drop.none", "Reject", State.none } }) |spec| {
        const button = try ui.widgets.Button(.{ .label = spec[1], .on_click = cx.on(State, state, spec[2]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = spec[0];
        try row.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, row);
    const source = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 }, .background = ui.Color{ .r = 140, .g = 90, .b = 60, .a = 255 } }, .{});
    source.meta.ownership.meta.test_id = "drop.source";
    source.behavior.events.event_context = state;
    source.behavior.events.on_event = State.sourceEvent;
    try source.appendChild(cx.allocator, try ui.text(cx, "Native OLE source", .{ .font_size = 16, .color = ui.Color.WHITE }));
    try root.appendChild(cx.allocator, source);
    const preview_button = try ui.widgets.Button(.{ .label = "Toggle source preview", .on_click = cx.on(State, state, State.previewToggle) }).mount(scope, cx);
    preview_button.meta.ownership.meta.test_id = "drop.source-preview";
    try root.appendChild(cx.allocator, preview_button);
    try root.appendChild(cx.allocator, source_status);
    const cancel_button = try ui.widgets.Button(.{ .label = "Cancel native source", .on_click = cx.on(State, state, State.cancelSource) }).mount(scope, cx);
    cancel_button.meta.ownership.meta.test_id = "drop.source-cancel";
    try root.appendChild(cx.allocator, cancel_button);
    try root.appendChild(cx.allocator, status);
    try root.appendChild(cx.allocator, hash);
    const capability = try ui.text(cx, if (app.sdk.capabilities.drag_drop_target) "OLE registered" else "OLE unavailable", .{ .font_size = 12, .color = ui.Color.WHITE });
    capability.meta.ownership.meta.test_id = "drop.capability";
    try root.appendChild(cx.allocator, capability);
    const modes = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 40 }, .direction = .row, .gap = 8 }, .{});
    inline for (.{ .{ "text", State.sourceText }, .{ "file", State.sourceFile }, .{ "url", State.sourceUrl }, .{ "internal", State.sourceInternal }, .{ "uri", State.sourceUri } }) |spec| {
        const button = try ui.widgets.Button(.{ .label = spec[0], .on_click = cx.on(State, state, spec[1]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "drop.source-" ++ spec[0];
        try modes.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, modes);
    const operations = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 40 }, .direction = .row, .gap = 8 }, .{});
    inline for (.{ .{ "copy-only", State.sourceCopy }, .{ "all", State.sourceAll } }) |spec| {
        const button = try ui.widgets.Button(.{ .label = spec[0], .on_click = cx.on(State, state, spec[1]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "drop.source-" ++ spec[0];
        try operations.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, operations);
    return root;
}
