//! Figma 358:1490644 / 358:1493475 / 358:1495172: four 184×44
//! editable image chips, 28×28 preview, explicit processing/error lifecycle.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const images = @import("../ai/image_attachments.zig");
const S = @import("ai_attachments_styles.zig");
const I = @import("ai_image_attachments_styles.zig");
pub const Callbacks = struct {
    context: *anyopaque,
    preview_sent: ?*const fn (*anyopaque, images.ContentRef) anyerror!void = null,
    remove: ?*const fn (*anyopaque, images.Ticket) anyerror!void = null,
    retry: ?*const fn (*anyopaque, images.Ticket) anyerror!void = null,
    visibility: ?*const fn (*anyopaque, bool) void = null,
    on_error: ?*const fn (*anyopaque, anyerror) void = null,
};
const Card = struct {
    view: *View,
    ticket: ?images.Ticket = null,
    root: *ui.Node = undefined,
    filename: *ui.Node = undefined,
    metadata: *ui.Node = undefined,
    preview: *ui.Node = undefined,
    retry_button: *ui.Node = undefined,
    remove_button: *ui.Node = undefined,
    reference: images.ContentRef = .{},
    texture: ?u32 = null,
    fn open(self: *Card) void {
        self.view.open(self) catch |err| self.view.fail(err);
    }
    fn remove(self: *Card) void {
        if (self.ticket) |ticket| if (self.view.callbacks.remove) |callback| callback(self.view.callbacks.context, ticket) catch |err| self.view.fail(err);
    }
    fn retry(self: *Card) void {
        if (self.ticket) |ticket| if (self.view.callbacks.retry) |callback| callback(self.view.callbacks.context, ticket) catch |err| self.view.fail(err);
    }
    fn release(self: *Card) void {
        self.reference.release();
        if (self.texture) |texture| if (self.view.app) |app| app.renderer.image_renderer.unloadTexture(texture);
        self.texture = null;
    }
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    app: ?*App = null,
    root: *ui.Node = undefined,
    rail: ui.widgets.scroll_area.ScrollAreaResult = undefined,
    detached_wrapper: ?*ui.Node = null,
    keep_button: *ui.Node = undefined,
    preview_remove: *ui.Node = undefined,
    raster: *ui.Node = undefined,
    cards: [4]*Card = undefined,
    count: usize = 0,
    panel: *ui.Node = undefined,
    identity: *ui.Node = undefined,
    metadata: *ui.Node = undefined,
    preview_image: *ui.Node = undefined,
    preview_texture: ?u32 = null,
    preview_reference: images.ContentRef = .{},
    preview_ticket: ?images.Ticket = null,
    readonly: bool = false,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks, preview_parent: *ui.Node) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .callbacks = callbacks });
        try scope.onCleanup(View, self, release);
        self.root = try ui.boxStyled(cx, S.wrapper, .{});
        self.rail = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .height = S.rail_height }).mount(scope, cx);
        self.rail.container.setStyleInline(cx.allocator, S.viewport());
        self.rail.content.setStyleInline(cx.allocator, S.rail());
        try self.root.appendChild(cx.allocator, self.rail.container);
        self.root.meta.ownership.meta.test_id = "ai.images";
        self.root.setDisplay(.none);
        for (&self.cards) |*slot| {
            const card = try scope.createState(Card, .{ .view = self });
            slot.* = card;
            card.root = try ui.boxStyled(cx, S.card, .{});
            card.root.meta.ownership.meta.test_id = "ai.image";
            card.root.setDisplay(.none);
            try self.rail.content.appendChild(cx.allocator, card.root);
            card.preview = try self.button(card.root, "ai.image.preview", "查看图片", ui.icons.image, cx.on(Card, card, Card.open));
            card.preview.setStyleInline(cx.allocator, S.previewSlot());
            card.filename = try ui.textStyled(cx, S.filename, "");
            card.filename.setStyleInline(cx.allocator, S.filenameSlot());
            try card.root.appendChild(cx.allocator, card.filename);
            card.metadata = try ui.textStyled(cx, S.metadata, "");
            card.metadata.setStyleInline(cx.allocator, S.metadataSlot());
            card.metadata.meta.ownership.meta.test_id = "ai.image.state";
            try card.root.appendChild(cx.allocator, card.metadata);
            const remove = try self.button(card.root, "ai.image.remove", "移除图片", ui.icons.x, cx.on(Card, card, Card.remove));
            card.remove_button = remove;
            remove.setStyleInline(cx.allocator, S.removeSlot());
            card.retry_button = try self.button(card.root, "ai.image.retry", "重试附件", ui.icons.get("rotate-cw").?, cx.on(Card, card, Card.retry));
            card.retry_button.setStyleInline(cx.allocator, I.retrySlot());
        }
        self.panel = try ui.boxStyled(cx, S.inlinePreview, .{});
        self.panel.meta.ownership.meta.test_id = "ai.image.preview.panel";
        self.panel.setDisplay(.none);
        try preview_parent.appendChild(cx.allocator, self.panel);
        const heading = try ui.boxStyled(cx, S.heading, .{});
        try self.panel.appendChild(cx.allocator, heading);
        const title_icon = try ui.iconTint(cx, ui.icons.image, S.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        title_icon.meta.ownership.meta.test_id = "ai.image.preview.title.icon";
        try heading.appendChild(cx.allocator, title_icon);
        const title = try ui.textStyled(cx, S.headingText, "图片预览");
        title.setStyleInline(cx.allocator, S.fillLabel());
        try heading.appendChild(cx.allocator, title);
        _ = try self.button(heading, "ai.image.preview.close", "关闭预览", ui.icons.x, cx.on(View, self, dismiss));
        const identity_row = try ui.boxStyled(cx, S.identity, .{});
        try self.panel.appendChild(cx.allocator, identity_row);
        self.identity = try ui.textStyled(cx, S.identityText, "");
        self.identity.setStyleInline(cx.allocator, S.fillLabel());
        try identity_row.appendChild(cx.allocator, self.identity);
        self.keep_button = try self.button(identity_row, "ai.image.preview.keep", "保留图片", ui.icons.check, cx.on(View, self, dismiss));
        self.preview_remove = try self.button(identity_row, "ai.image.preview.remove", "移除图片", ui.icons.x, cx.on(View, self, removePreview));
        const source_row = try ui.boxStyled(cx, S.source, .{});
        try self.panel.appendChild(cx.allocator, source_row);
        self.metadata = try ui.textStyled(cx, S.sourceText, "");
        self.metadata.setStyleInline(cx.allocator, S.fillLabel());
        try source_row.appendChild(cx.allocator, self.metadata);
        self.preview_image = try ui.box(cx, I.previewStyle(), .{});
        self.preview_image.meta.ownership.meta.test_id = "ai.image.preview.raster";
        try self.panel.appendChild(cx.allocator, self.preview_image);
        self.raster = try ui.box(cx, .{}, .{});
        try self.preview_image.appendChild(cx.allocator, self.raster);
        return self;
    }
    /// Place the existing image card group in the shared captured-text rail.
    /// The parent owns scrolling; image refs and callbacks keep their own scope.
    pub fn shareRail(self: *View, parent: *ui.Node) !void {
        self.rail.container.removeChild(self.rail.content);
        self.detached_wrapper = self.root;
        self.root = self.rail.content;
        self.root.meta.ownership.meta.test_id = "ai.images";
        try parent.appendChild(self.cx.allocator, self.root);
    }
    pub fn update(self: *View, draft: ?*const images.Draft) !void {
        const count = if (draft) |value| value.items.items.len else 0;
        self.count = count;
        for (self.cards, 0..) |card, index| {
            if (index >= count) {
                card.root.setDisplay(.none);
                card.ticket = null;
                card.release();
                continue;
            }
            const item = draft.?.items.items[index];
            try self.updateCard(card, item.ticket, item.path, item.state, item.reference);
        }
        self.root.setDisplay(if (count > 0) .flex else .none);
        if (self.preview_ticket) |ticket| {
            var found = false;
            if (draft) |value| for (value.items.items) |item| {
                if (item.ticket.eql(ticket)) found = true;
            };
            if (!found) self.dismiss();
        }
    }
    pub fn updateSent(self: *View, bundle: *const images.Bundle) !void {
        self.readonly = true;
        self.count = bundle.items.len;
        for (self.cards, 0..) |card, index| {
            if (index >= bundle.items.len) {
                card.root.setDisplay(.none);
                card.ticket = null;
                card.release();
                continue;
            }
            const item = bundle.items[index];
            const content = item.reference.content() orelse return error.EmptyAttachmentResult;
            try self.updateCard(card, .{ .owner = bundle.owner, .draft_epoch = bundle.draft_epoch, .id = item.id }, content.path, .ready, item.reference);
        }
        self.root.setDisplay(if (self.count > 0) .flex else .none);
    }
    fn updateCard(self: *View, card: *Card, ticket: images.Ticket, path: []const u8, state: images.State, reference: images.ContentRef) !void {
        card.ticket = ticket;
        card.root.setDisplay(.flex);
        try card.filename.setTextContent(self.cx.allocator, std.fs.path.basename(path));
        var buffer: [160]u8 = undefined;
        const text = if (reference.content()) |content| try std.fmt.bufPrint(&buffer, "{s} {d}×{d} · {d} B", .{ @tagName(content.mime), content.width, content.height, content.bytes.len }) else if (state == .processing) "图片处理中" else "读取失败 · 可重试";
        try card.metadata.setTextContent(self.cx.allocator, text);
        card.metadata.setDisplay(if (state == .ready) .none else .flex);
        card.remove_button.setDisplay(if (self.readonly) .none else .flex);
        card.retry_button.setDisplay(if (!self.readonly and state == .failed) .flex else .none);
        // Keep resource ownership independent of mutable draft/remove callbacks.
        if (card.reference.snapshot != reference.snapshot) {
            card.release();
            card.preview.setImage(null);
            for (card.preview.children.items) |child| child.setDisplay(if (reference.content() == null) .flex else .none);
            card.reference = reference.retain();
            if (reference.content()) |content| if (self.app) |app| {
                card.texture = try app.renderer.image_renderer.loadTexture(content.width, content.height, content.pixels);
                // The button's existing icon is replaced by the actual raster.
                card.preview.setImage(.{ .texture_id = card.texture.? });
            };
        }
    }
    fn open(self: *View, card: *Card) !void {
        if (self.readonly) if (self.callbacks.preview_sent) |callback| return callback(self.callbacks.context, card.reference);
        try self.openPreview(card.reference, if (self.readonly) null else card.ticket);
    }
    pub fn openSentPreview(self: *View, reference: images.ContentRef) !void {
        try self.openPreview(reference, null);
    }
    fn openPreview(self: *View, reference: images.ContentRef, ticket: ?images.Ticket) !void {
        const content = reference.content() orelse return;
        self.preview_reference.release();
        self.preview_reference = reference.retain();
        self.preview_ticket = ticket;
        self.preview_remove.setDisplay(if (ticket == null) .none else .flex);
        self.keep_button.setDisplay(if (ticket == null) .none else .flex);
        try self.identity.setTextContent(self.cx.allocator, content.path);
        var buffer: [160]u8 = undefined;
        try self.metadata.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "本地 · {s} · {d}×{d} · {d} B", .{ content.mime.name(), content.width, content.height, content.bytes.len }));
        if (self.preview_texture) |texture| if (self.app) |app| app.renderer.image_renderer.unloadTexture(texture);
        self.preview_texture = null;
        if (self.app) |app| {
            self.preview_texture = try app.renderer.image_renderer.loadTexture(content.width, content.height, content.pixels);
            self.raster.setImage(.{ .texture_id = self.preview_texture.? });
            self.raster.setStyleInline(self.cx.allocator, I.raster(content.width, content.height));
        }
        self.panel.setDisplay(.flex);
        if (self.callbacks.visibility) |callback| callback(self.callbacks.context, true);
        self.cx.requestRedraw();
    }
    fn removePreview(self: *View) void {
        const ticket = self.preview_ticket orelse return;
        if (self.callbacks.remove) |callback| callback(self.callbacks.context, ticket) catch |err| {
            self.fail(err);
            return;
        };
        self.dismiss();
    }
    pub fn height(self: *const View) f32 {
        return if (self.count > 0) S.rail_height + S.input_gap else 0;
    }
    pub fn isPreviewOpen(self: *const View) bool {
        return self.panel.style.display != .none;
    }
    pub fn dismiss(self: *View) void {
        self.panel.setDisplay(.none);
        self.preview_ticket = null;
        self.preview_reference.release();
        self.raster.setImage(null);
        if (self.preview_texture) |texture| if (self.app) |app| app.renderer.image_renderer.unloadTexture(texture);
        self.preview_texture = null;
        if (self.callbacks.visibility) |callback| callback(self.callbacks.context, false);
    }
    pub fn escapePreview(self: *View) bool {
        if (self.panel.style.display == .none) return false;
        self.dismiss();
        return true;
    }
    fn fail(self: *View, err: anyerror) void {
        if (self.callbacks.on_error) |callback| callback(self.callbacks.context, err);
    }
    fn button(self: *View, parent: *ui.Node, id: []const u8, label: []const u8, asset: ui.SvgAsset, on_click: ui.Handler(void)) !*ui.Node {
        const button_node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = label, .base_style = S.iconButton(), .on_click = on_click }).mount(self.scope, self.cx);
        button_node.meta.ownership.meta.test_id = id;
        try button_node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, asset, S.theme.current().fg_2, .{ .width = .{ .px = S.icon_size }, .height = .{ .px = S.icon_size } }));
        try parent.appendChild(self.cx.allocator, button_node);
        return button_node;
    }
    fn release(self: *View) void {
        if (self.detached_wrapper) |node| self.cx.destroyDetached(node);
        if (self.panel.parent) |parent| {
            self.cx.detachChild(parent, self.panel);
            self.cx.destroyDetached(self.panel);
        }
        for (self.cards) |card| card.release();
        self.preview_reference.release();
        if (self.preview_texture) |texture| if (self.app) |app| app.renderer.image_renderer.unloadTexture(texture);
    }
};
