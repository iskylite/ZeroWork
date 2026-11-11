const std = @import("std");
const ui = @import("ui");
const assets = @import("assets.zig");
const frames = @import("../../host/frame_texture_sink.zig");
const image_api = @import("../../ai/image_attachments.zig");
const model = @import("model.zig");
const sessions = @import("document_sessions.zig");
const Store = @import("store.zig").Store;
const S = @import("styles.zig");

pub const ImportInput = union(enum) { file: []const u8, clipboard: []const u8 };

pub const Import = struct {
    store: *Store,
    ticket: sessions.ImportTicket,
    input: ImportInput,
    cancel: assets.CancelToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!assets.Imported = error.Cancelled,
    thread: std.Thread = undefined,

    pub fn start(a: std.mem.Allocator, store: *Store, ticket: sessions.ImportTicket, input: ImportInput) !*Import {
        const self = try a.create(Import);
        errdefer a.destroy(self);
        const bytes = try a.dupe(u8, switch (input) {
            .file, .clipboard => |bytes| bytes,
        });
        errdefer a.free(bytes);
        self.* = .{
            .store = store,
            .ticket = ticket,
            .input = switch (input) {
                .file => .{ .file = bytes },
                .clipboard => .{ .clipboard = bytes },
            },
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Import) void {
        defer self.done.store(true, .release);
        const a = std.heap.page_allocator;
        const library = self.ticket.stamp.lease.key.library_id;
        self.result = switch (self.input) {
            .file => |path| assets.importFile(a, self.store, library, path, &self.cancel, .{}),
            .clipboard => |bytes| assets.importBytes(a, self.store, library, bytes, &self.cancel, .{}),
        };
    }

    pub fn deinit(self: *Import, a: std.mem.Allocator) void {
        self.cancel.cancel();
        self.thread.join();
        a.free(switch (self.input) {
            .file, .clipboard => |bytes| bytes,
        });
        a.destroy(self);
    }
};

/// The persisted reference is an independent block; adjacent prose stays
/// byte-for-byte intact and is separated only when it needs a new paragraph.
pub fn insertion(a: std.mem.Allocator, body: []const u8, range: sessions.Range, path: []const u8) ![]u8 {
    try validateInsertion(body, range);
    const before = body[0..range.start];
    const after = body[range.end..];
    const prefix = if (before.len == 0 or std.mem.endsWith(u8, before, "\n\n")) "" else if (std.mem.endsWith(u8, before, "\n")) "\n" else "\n\n";
    const suffix = if (after.len == 0 or std.mem.startsWith(u8, after, "\n\n")) "" else if (std.mem.startsWith(u8, after, "\n")) "\n" else "\n\n";
    return std.fmt.allocPrint(a, "{s}![图片]({s}){s}", .{ prefix, path, suffix });
}

pub fn validateInsertion(body: []const u8, range: sessions.Range) !void {
    if (range.start > range.end or range.end > body.len) return error.InvalidRange;
    if (!assets.allowsImageParagraphAfter(body[0..range.start])) return error.InvalidImageLocation;
}

const Decode = struct {
    store: *Store,
    library: model.LibraryId,
    line: []const u8,
    path: []const u8,
    source: []u8,
    done: std.atomic.Value(bool) = .init(false),
    cancel: assets.CancelToken = .{},
    thread: std.Thread = undefined,
    image: anyerror!image_api.ContentRef = error.Cancelled,

    fn run(self: *Decode) void {
        defer self.done.store(true, .release);
        self.image = assets.readReferenced(std.heap.page_allocator, self.store, self.library, self.line, self.path, &self.cancel, .{});
    }

    fn release(self: *Decode, a: std.mem.Allocator) void {
        self.cancel.cancel();
        self.thread.join();
        if (self.image) |value| {
            var image = value;
            image.release();
        } else |_| {}
        a.free(self.source);
        a.destroy(self);
    }
};

pub const Open = struct {
    context: *anyopaque,
    show: *const fn (*anyopaque, *Image) void,
};

pub const Image = struct {
    cx: *ui.Cx,
    store: *Store,
    library: model.LibraryId,
    backend: frames.Backend,
    line: *ui.Signal([]const u8),
    path: *ui.Signal([]const u8),
    node: *ui.Node,
    label: *ui.Node,
    open: Open,
    pinned: bool = false,
    texture: ?u32 = null,
    job: ?*Decode = null,
    decoded: struct { width: u32 = 0, height: u32 = 0 } = .{},
    rendered_width: f32 = 0,
    failed: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, store: *Store, library: model.LibraryId, backend: frames.Backend, line: []const u8, source: assets.ImageLine, append_to: *ui.Node, open: Open) !*Image {
        const node = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .flex_shrink = 0, .hit_behavior = .@"opaque" }, .{});
        const label = try ui.text(cx, "", S.text(13, 400, S.theme.current().fg_2));
        try label.setTextContent(cx.allocator, if (source.alt.len == 0) "图片" else source.alt);
        try node.appendChild(cx.allocator, label);
        const self = try scope.createState(Image, .{
            .cx = cx,
            .store = store,
            .library = library,
            .backend = backend,
            .line = try scope.createText(line, .{}),
            .path = try scope.createText(source.relative_path, .{}),
            .node = node,
            .label = label,
            .open = open,
        });
        try scope.onCleanup(Image, self, cleanup);
        node.meta.ownership.meta.test_id = "notes.document.image";
        node.behavior.events.on_click = cx.on(Image, self, showPreview);
        node.behavior.interaction.a11y = .{ .role = .button, .label = "查看图片" };
        try append_to.appendChild(cx.allocator, node);
        return self;
    }

    pub fn pause(self: *Image) void {
        if (self.job) |job| job.cancel.cancel();
    }

    pub fn bytes(self: *const Image) usize {
        if (self.texture == null) return 0;
        return @as(usize, self.decoded.width) * self.decoded.height * 4;
    }

    pub fn evict(self: *Image) void {
        if (self.pinned) return;
        if (self.texture) |id| {
            self.backend.release(self.backend.context, id);
            self.texture = null;
            self.node.setImage(null);
            self.label.setDisplay(.flex);
        }
    }

    /// Called on the presentation thread. Decode and disk work stay in a
    /// bounded visible queue, while texture ownership follows the block scope.
    pub fn tick(self: *Image, visible: bool, available_width: f32, permit_start: bool, budget: usize) !bool {
        var changed = false;
        if (self.job) |job| {
            if (!job.done.load(.acquire)) return false;
            self.job = null;
            defer job.release(self.cx.allocator);
            if (!visible or job.cancel.isCancelled()) return false;
            const result = job.image catch {
                self.failed = true;
                return false;
            };
            const image = result.content() orelse return false;
            if (image.pixels.len > budget) {
                self.failed = true;
                return false;
            }
            const texture = try self.backend.create(self.backend.context, image.width, image.height);
            errdefer self.backend.release(self.backend.context, texture);
            try self.backend.update(self.backend.context, texture, image.pixels);
            self.texture = texture;
            self.decoded = .{ .width = image.width, .height = image.height };
            self.label.setDisplay(.none);
            self.node.setImage(.{ .texture_id = texture });
            changed = true;
        }
        if (self.texture != null) {
            const width: f32 = @floatFromInt(self.decoded.width);
            const height: f32 = @floatFromInt(self.decoded.height);
            const scale = @min(1, available_width / width);
            if (@abs(self.rendered_width - width * scale) > 0.25) {
                self.rendered_width = width * scale;
                self.node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width * scale }, .height = .{ .px = height * scale } });
                changed = true;
            }
        } else if (visible and !self.failed and permit_start and budget > 0) {
            const decode = try self.cx.allocator.create(Decode);
            errdefer self.cx.allocator.destroy(decode);
            const line = self.line.peek();
            const source = try std.mem.concat(self.cx.allocator, u8, &.{ line, self.path.peek() });
            errdefer self.cx.allocator.free(source);
            decode.* = .{ .store = self.store, .library = self.library, .line = source[0..line.len], .path = source[line.len..], .source = source };
            decode.thread = try std.Thread.spawn(.{}, Decode.run, .{decode});
            self.job = decode;
        }
        return changed;
    }

    fn showPreview(self: *Image) void {
        if (self.texture != null) self.open.show(self.open.context, self);
    }

    fn cleanup(self: *Image) void {
        if (self.job) |job| job.release(self.cx.allocator);
        if (self.texture) |texture| self.backend.release(self.backend.context, texture);
    }
};

test "notes image insertion keeps adjacent text and inserts a standalone image" {
    const a = std.testing.allocator;
    const value = try insertion(a, "正文尾", .{ .start = 6, .end = 6 }, "assets/example.png");
    defer a.free(value);
    try std.testing.expectEqualStrings("\n\n![图片](assets/example.png)\n\n", value);
}

test "notes image insertion preserves selected text inside fenced code or a comment" {
    const a = std.testing.allocator;
    const path = "assets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png";
    for ([_][]const u8{ "```zig\n", "~~~\n", "<!--\n" }) |prefix| {
        const body = try std.mem.concat(a, u8, &.{ prefix, "原文" });
        defer a.free(body);
        try std.testing.expectError(error.InvalidImageLocation, insertion(a, body, .{ .start = prefix.len, .end = body.len }, path));
    }
    const closed = "```zig\n代码\n```\n\n<!-- 说明 -->\n";
    const value = try insertion(a, closed, .{ .start = closed.len, .end = closed.len }, path);
    defer a.free(value);
    const body = try std.mem.concat(a, u8, &.{ closed, value });
    defer a.free(body);
    try std.testing.expect(assets.isReferenced(body, path));
}
