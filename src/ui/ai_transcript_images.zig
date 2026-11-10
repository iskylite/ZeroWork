//! UI-only path previews. This store has no access to provider messages/drafts.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Application = @import("application_host.zig").ApplicationHost;
const images = @import("../ai/image_attachments.zig");
const files = @import("../host/terminal_files.zig");
const Source = @import("../ai/terminal_file_source.zig").Source;
const Job = @import("terminal_file_job.zig").Job;
const S = @import("ai_transcript_images_styles.zig");
pub const Reference = struct { start: usize, end: usize, alt: []const u8, path: []const u8 };
fn insideCode(prefix: []const u8) bool {
    var marker: usize = 0;
    var i: usize = 0;
    while (i < prefix.len) {
        if (prefix[i] == '\\') {
            i += @min(@as(usize, 2), prefix.len - i);
            continue;
        }
        if (prefix[i] != '`') {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < prefix.len and prefix[end] == '`') end += 1;
        const run = end - i;
        if (marker == 0) marker = run else if (marker == run) marker = 0;
        i = end;
    }
    return marker != 0;
}
pub fn reference(line: []const u8) ?Reference {
    if (std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t")) return null;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, line, offset, "![")) |start| {
        offset = start + 2;
        // Escaped markup and inline code remain literal.
        if ((start != 0 and line[start - 1] == '\\') or insideCode(line[0..start])) continue;
        const middle = std.mem.indexOfPos(u8, line, offset, "](") orelse return null;
        var end = middle + 2;
        var depth: usize = 1;
        while (end < line.len) : (end += 1) {
            if (line[end] == '(') depth += 1;
            if (line[end] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (end == line.len) return null;
        var path = std.mem.trim(u8, line[middle + 2 .. end], " \t");
        if (path.len >= 2 and path[0] == '<' and path[path.len - 1] == '>') path = path[1 .. path.len - 1];
        if (path.len == 0) return null;
        return .{ .start = start, .end = end + 1, .alt = line[start + 2 .. middle], .path = path };
    }
    return null;
}
const Entry = struct {
    store: *Store,
    turn: u64,
    conversation: u64,
    source: Source,
    path: []const u8,
    phase: enum { queued, loading, ready, failed } = .queued,
    failure: ?anyerror = null,
    job: ?*Job = null,
    image: images.ContentRef = .{},
    fn retry(self: *Entry) void {
        if (self.job != null) return;
        self.image.release();
        self.phase = .queued;
        self.failure = null;
        self.store.changed = true;
    }
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*Entry) = .empty,
    changed: bool = false,
    retained_bytes: usize = 0,
    pub fn entry(self: *Store, source: Source, conversation: u64, turn: u64, path: []const u8) !*Entry {
        const decoded = try fileUrl(self.allocator, source, path);
        defer if (decoded) |bytes| self.allocator.free(bytes);
        if (decoded == null and std.mem.indexOf(u8, path, "://") != null) return error.UnsupportedImageLink;
        const absolute = try files.pathFor(self.allocator, decoded orelse path, source.cwd);
        errdefer self.allocator.free(absolute);
        for (self.entries.items) |item| if (item.conversation == conversation and item.turn == turn and item.source.owner.eql(source.owner) and std.mem.eql(u8, item.path, absolute)) {
            self.allocator.free(absolute);
            return item;
        };
        if (self.entries.items.len >= 32) return error.ImagePreviewLimit;
        const item = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(item);
        const owned = try source.clone(self.allocator);
        errdefer {
            var value = owned;
            value.deinit(self.allocator);
        }
        item.* = .{ .store = self, .source = owned, .conversation = conversation, .turn = turn, .path = absolute };
        try self.entries.append(self.allocator, item);
        return item;
    }
    /// Called by the app's controller tick, never by a provider worker.
    pub fn tick(self: *Store, app: *Application) bool {
        var active = false;
        for (self.entries.items) |item| if (item.job) |job| {
            active = true;
            job.tick(app);
            if (!job.done) {
                if (job.reportable and item.phase != .failed) {
                    item.failure = job.result.failure orelse error.SshCleanupUnknown;
                    item.phase = .failed;
                    self.changed = true;
                }
                continue;
            }
            item.failure = job.result.failure;
            if (item.failure == null) {
                const content = job.image.content() orelse {
                    item.failure = error.InvalidImage;
                    item.phase = .failed;
                    job.deinit();
                    item.job = null;
                    self.changed = true;
                    continue;
                };
                const cost = content.bytes.len + content.pixels.len;
                if (cost > 128 * 1024 * 1024 -| self.retained_bytes) item.failure = error.ImagePreviewLimit else {
                    item.image = job.image.retain();
                    self.retained_bytes += cost;
                }
            }
            item.phase = if (item.failure == null) .ready else .failed;
            job.deinit();
            item.job = null;
            self.changed = true;
        };
        if (!active) for (self.entries.items) |item| {
            if (item.phase != .queued) continue;
            item.job = Job.start(self.allocator, app, item.source.owner, .{ .kind = .read_image, .path = item.path }, item.source.cwd) catch |err| {
                item.failure = err;
                item.phase = .failed;
                self.changed = true;
                continue;
            };
            item.phase = .loading;
            self.changed = true;
            break;
        };
        const changed = self.changed;
        self.changed = false;
        return changed;
    }
    pub fn busy(self: *Store) bool {
        for (self.entries.items) |item| if (item.job != null or item.phase == .queued) return true;
        return false;
    }
    pub fn cancel(self: *Store) void {
        for (self.entries.items) |item| {
            if (item.job) |job| job.stop() else if (item.phase == .queued) {
                item.phase = .failed;
                item.failure = error.Cancelled;
                self.changed = true;
            }
        }
    }
    pub fn stopOwner(self: *Store, owner: @import("../host/identity.zig").SessionHandle, app: *Application) @import("../host/session_host.zig").CloseReceipt {
        var waiting = false;
        var unknown = false;
        for (self.entries.items) |item| {
            if (!item.source.owner.eql(owner)) continue;
            if (item.job) |job| {
                job.stop();
                waiting = true;
                unknown = unknown or job.reportable;
            } else if (item.phase == .queued) {
                item.phase = .failed;
                item.failure = error.Cancelled;
                self.changed = true;
            }
        }
        if (waiting) {
            _ = self.tick(app);
            return if (unknown) .unknown else .awaiting;
        }
        return .released;
    }
    pub fn deinit(self: *Store) void {
        for (self.entries.items) |item| {
            std.debug.assert(item.job == null);
            item.image.release();
            item.source.deinit(self.allocator);
            self.allocator.free(item.path);
            self.allocator.destroy(item);
        }
        self.entries.deinit(self.allocator);
    }
};
fn fileUrl(a: std.mem.Allocator, source: Source, path: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, path, "file://")) return null;
    if (source.transport != .local) return error.UnsupportedImageLink;
    const raw = if (std.mem.startsWith(u8, path, "file:///")) path[7..] else if (std.mem.startsWith(u8, path, "file://localhost/")) path[16..] else return error.UnsupportedImageLink;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%') {
            if (raw.len - i < 3) return error.InvalidFilePath;
            try out.append(a, std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidFilePath);
            i += 2;
        } else try out.append(a, raw[i]);
    }
    return try out.toOwnedSlice(a);
}
pub const Context = struct {
    store: *Store,
    source: ?Source,
    conversation: u64,
    turn: u64,
    app: ?*App,
    preview_context: *anyopaque,
    preview: *const fn (*anyopaque, images.ContentRef) anyerror!void,
};
const View = struct {
    context: Context,
    entry: *Entry,
    texture: ?u32 = null,
    fn open(self: *View) void {
        self.context.preview(self.context.preview_context, self.entry.image) catch {};
    }
    fn reload(self: *View) void {
        if (self.entry.image.content()) |content| self.entry.store.retained_bytes -|= content.bytes.len + content.pixels.len;
        self.entry.retry();
    }
    fn cleanup(self: *View) void {
        if (self.texture) |id| if (self.context.app) |app| app.renderer.image_renderer.unloadTexture(id);
    }
};
const ImageLayout = struct {
    cx: *ui.Cx,
    card: *ui.Node,
    raster: *ui.Node,
    width: f32,
    height: f32,

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *ImageLayout = @ptrCast(@alignCast(raw));
        const bounds = self.card.globalRect();
        if (bounds.w <= 0) return .done;
        const available = @max(1, bounds.w - self.card.style.padding.horizontal());
        const scale = @min(@as(f32, 1), @min(available / self.width, 240 / self.height));
        const width = self.width * scale;
        const height = self.height * scale;
        const raster = self.raster.globalRect();
        if (@abs(raster.w - width) <= 0.1 and @abs(raster.h - height) <= 0.1) return .done;
        self.raster.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
        return .needs_layout;
    }

    fn release(self: *ImageLayout) void {
        self.cx.removeAfterLayoutHook(self);
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, context: Context, ref: Reference, width: f32) !*ui.Node {
    const root = try ui.boxStyled(cx, S.card, .{});
    @import("layer_materials.zig").card(root, .control);
    root.meta.ownership.meta.test_id = "ai.transcript.image";
    const source = context.source orelse {
        try root.appendChild(cx.allocator, try ui.textStyled(cx, S.metadata, "无法确定图片所属的本地或 SSH 会话"));
        return root;
    };
    const item = context.store.entry(source, context.conversation, context.turn, ref.path) catch |err| {
        try root.appendChild(cx.allocator, try ui.textStyled(cx, S.metadata, errorLabel(err)));
        return root;
    };
    const view = try scope.createState(View, .{ .context = context, .entry = item });
    try scope.onCleanup(View, view, View.cleanup);
    const identity_text = try std.fmt.allocPrint(cx.allocator, "{s} · #{d} · {s}", .{ if (source.transport == .local) @as([]const u8, "本地") else "SSH", @backingInt(source.owner.session_id), item.path });
    defer cx.allocator.free(identity_text);
    const label = try ui.textStyled(cx, S.metadata, identity_text);
    label.meta.ownership.meta.test_id = "ai.transcript.image.source";
    try root.appendChild(cx.allocator, label);
    if (item.image.content()) |content| {
        const scale = @min(@as(f32, 1), @min(@max(1, width - 20) / @as(f32, @floatFromInt(content.width)), 240 / @as(f32, @floatFromInt(content.height))));
        const raster = try ui.box(cx, .{ .width = .{ .px = @as(f32, @floatFromInt(content.width)) * scale }, .height = .{ .px = @as(f32, @floatFromInt(content.height)) * scale }, .flex_shrink = 0 }, .{});
        raster.meta.ownership.meta.test_id = "ai.transcript.image.raster";
        if (context.app) |app| {
            view.texture = try app.renderer.image_renderer.loadTexture(content.width, content.height, content.pixels);
            raster.setImage(.{ .texture_id = view.texture.? });
        }
        try root.appendChild(cx.allocator, raster);
        const layout = try scope.createState(ImageLayout, .{ .cx = cx, .card = root, .raster = raster, .width = @floatFromInt(content.width), .height = @floatFromInt(content.height) });
        try scope.onCleanup(ImageLayout, layout, ImageLayout.release);
        try cx.addAfterLayoutHook(layout, ImageLayout.afterLayout);
        var time_buffer: [64]u8 = undefined;
        const captured = @import("history_styles.zig").dateLabel(&time_buffer, @intCast(content.captured_at_ms));
        const dimensions = try std.fmt.allocPrint(cx.allocator, "{d} × {d} · {d} 字节 · {s}", .{ content.width, content.height, content.bytes.len, captured });
        defer cx.allocator.free(dimensions);
        try root.appendChild(cx.allocator, try ui.textStyled(cx, S.metadata, dimensions));
    } else {
        const status = try ui.textStyled(cx, S.metadata, if (item.failure) |err| errorLabel(err) else "正在读取图片…");
        status.meta.ownership.meta.test_id = "ai.transcript.image.status";
        try root.appendChild(cx.allocator, status);
    }
    const actions = try ui.hstack(cx, .{ .gap = 8, .flex_shrink = 0 }, .{});
    if (item.phase == .ready) {
        const open = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get("maximize-2").?, .icon_size = 16, .a11y_label = "查看图片", .variant = .ghost, .on_click = cx.on(View, view, View.open), .base_style = S.button(cx.tokens) }).mount(scope, cx);
        open.meta.ownership.meta.test_id = "ai.transcript.image.open";
        const open_hint = try @import("control_hint.zig").mount(cx, scope, open, "查看图片", .{ .id = "ai.transcript.image.open.tooltip" });
        try actions.appendChild(cx.allocator, open_hint.wrapper);
    }
    if (item.job == null and (item.phase == .ready or item.phase == .failed)) {
        const reload = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get("rotate-cw").?, .icon_size = 16, .a11y_label = if (item.phase == .failed) "重试加载图片" else "重新加载图片", .variant = .ghost, .on_click = cx.on(View, view, View.reload), .base_style = S.button(cx.tokens) }).mount(scope, cx);
        reload.meta.ownership.meta.test_id = "ai.transcript.image.reload";
        const reload_hint = try @import("control_hint.zig").mount(cx, scope, reload, if (item.phase == .failed) @as([]const u8, "重试加载图片") else "重新加载图片", .{ .id = "ai.transcript.image.reload.tooltip" });
        try actions.appendChild(cx.allocator, reload_hint.wrapper);
    }
    try root.appendChild(cx.allocator, actions);
    return root;
}
fn errorLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "文件不存在",
        error.StaleBinding, error.StaleSession => "原会话不可用",
        error.FileTooLarge, error.ImageTooLarge => "图片超过大小或像素限制",
        error.AccessDenied, error.PermissionDenied => "没有文件读取权限",
        error.UnsupportedImage, error.AnimatedImageUnsupported => "不支持此图片格式或动画",
        error.ImagePreviewLimit => "图片预览已达到资源上限",
        error.UnsupportedImageLink => "仅支持本地和当前 SSH 会话的文件图片",
        error.Cancelled => "图片读取已取消",
        error.SshCleanupUnknown => "原 SSH 读取尚未释放，等待连接清理",
        else => "图片读取失败",
    };
}
test "transcript image references keep paths literal and ignore code escaped and incomplete syntax" {
    const value = reference("结果：![图](</tmp/a b.png>) 完成").?;
    try std.testing.expectEqualStrings("/tmp/a b.png", value.path);
    try std.testing.expect(reference("`![图](/tmp/a.png)`") == null);
    try std.testing.expect(reference("``![图](/tmp/a.png)``") == null);
    try std.testing.expect(reference("    ![图](/tmp/a.png)") == null);
    try std.testing.expect(reference("\\![图](/tmp/a.png)") == null);
    try std.testing.expect(reference("![图](/tmp/a.png") == null);
    const source: Source = .{ .owner = .{ .session_id = @fromBackingInt(1) } };
    const decoded = (try fileUrl(std.testing.allocator, source, "file:///tmp/a%20b.png")).?;
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("/tmp/a b.png", decoded);
    try std.testing.expectError(error.UnsupportedImageLink, fileUrl(std.testing.allocator, .{ .owner = source.owner, .transport = .ssh }, "file:///tmp/a.png"));
}
