//! Captured local-file and original-terminal draft entries. No IO or active-owner lookup.
const std = @import("std");
const ui = @import("ui");
const attachments = @import("../ai/local_text_attachments.zig");
const S = @import("ai_attachments_styles.zig");
pub const Callbacks = struct {
    context: *anyopaque,
    remove: ?*const fn (*anyopaque, attachments.Ticket) anyerror!void = null,
    attach: ?*const fn (*anyopaque, attachments.Ticket) anyerror!void = null,
    reselect: ?*const fn (*anyopaque, attachments.Ticket) anyerror!void = null,
    preview_sent: ?*const fn (*anyopaque, attachments.Ticket, attachments.ContentRef) anyerror!void = null,
    preview_visibility: ?*const fn (*anyopaque, bool) void = null,
    on_error: ?*const fn (*anyopaque, anyerror) void = null,
};
const Card = struct {
    view: *View,
    ticket: attachments.Ticket,
    root: *ui.Node = undefined,
    preview: *ui.Node = undefined,
    filename: *ui.Node = undefined,
    metadata: *ui.Node = undefined,
    remove_style: *ui.Signal(S.ButtonStyle),
    preview_style: *ui.Signal(S.ButtonStyle),
    hover_style: *ui.Signal(?ui.BoxStyle),
    removing: *ui.Signal(bool),
    icons: [2]*ui.Node = undefined,
    fn open(self: *Card) void {
        self.view.openCaptured(self.ticket) catch |err| self.view.fail(err);
    }
    fn remove(self: *Card) void {
        if (self.removing.peek()) return;
        if (!self.view.contains(self.ticket)) return;
        const callback = self.view.callbacks.remove orelse return;
        callback(self.view.callbacks.context, self.ticket) catch |err| {
            self.view.fail(err);
            return;
        };
        self.removing.set(true);
    }
    fn retheme(self: *Card) void {
        self.remove_style.set(S.iconButton());
        self.preview_style.set(S.previewButton());
        self.hover_style.set(S.hover());
        self.root.setBackground(S.theme.current().surface_2);
        self.filename.setTextColor(S.theme.current().fg_1);
        self.metadata.setTextColor(S.theme.current().fg_2);
        _ = self.icons[0].setTint(S.theme.current().accent);
        _ = self.icons[1].setTint(S.theme.current().fg_2);
    }
};

pub const View = struct {
    const Candidate = struct { ticket: attachments.Ticket, reference: attachments.ContentRef };
    const PreviewKind = enum { candidate, draft, history };
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    rail: ui.widgets.scroll_area.ScrollAreaResult = undefined,
    cards_scope: ?*ui.Scope = null,
    external_rail: ?*ui.Node = null,
    external_count: usize = 0,
    cards: std.ArrayList(*Card) = .empty,
    source: ?attachments.Bundle = null,
    pending: ?attachments.Bundle = null,
    pending_update: bool = false,
    candidate: ?Candidate = null,
    pending_candidate: ?Candidate = null,
    readonly: bool = false,
    pending_readonly: bool = false,
    popup: ?ui.widgets.popover.PopoverResult = null,
    modal: ?ui.widgets.ModalResult = null,
    modal_open: ?*ui.Signal(bool) = null,
    modal_card: ?*ui.Node = null,
    modal_body: ?*ui.Node = null,
    inline_parent: ?*ui.Node = null,
    preview_panel: *ui.Node = undefined,
    preview_scope: *ui.Scope = undefined,
    inline_open: bool = false,
    preview_body: ui.widgets.scroll_area.ScrollAreaResult = undefined,
    preview_label: *ui.Node = undefined,
    preview_title: *ui.Node = undefined,
    preview_identity_box: *ui.Node = undefined,
    preview_identity: *ui.Node = undefined,
    preview_metadata: *ui.Node = undefined,
    preview_info: *ui.Node = undefined,
    preview_info_text: *ui.Signal([]const u8) = undefined,
    preview_terminal_icon: *ui.Node = undefined,
    preview_primary_check: *ui.Node = undefined,
    preview_primary_plus: *ui.Node = undefined,
    preview_reference: attachments.ContentRef = .{},
    preview_ticket: ?attachments.Ticket = null,
    preview_kind: ?PreviewKind = null,
    preview_primary: *ui.Node = undefined,
    preview_remove: *ui.Node = undefined,
    preview_reselect: *ui.Node = undefined,
    preview_icons: [2]*ui.Node = undefined,
    icon_style: *ui.Signal(S.ButtonStyle),
    icon_hover: *ui.Signal(?ui.BoxStyle),
    colors: S.theme.Colors,
    last_error: ?anyerror = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        return mountAt(cx, scope, callbacks, null);
    }

    /// R11 resources occupy the conversation viewport, not a second surface
    /// anchored above the composer. The host owns this stable inline parent.
    pub fn mountInline(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks, preview_parent: *ui.Node) !*View {
        return mountAt(cx, scope, callbacks, preview_parent);
    }

    fn mountAt(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks, preview_parent: ?*ui.Node) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .callbacks = callbacks, .icon_style = try scope.createSignal(S.ButtonStyle, S.iconButton()), .icon_hover = try scope.createSignal(?ui.BoxStyle, S.hover()), .colors = S.theme.current() });
        self.inline_parent = preview_parent;
        try scope.onCleanup(View, self, release);
        self.root = try ui.boxStyled(cx, S.wrapper, .{});
        self.root.meta.ownership.meta.test_id = "ai.attachments";
        self.root.setDisplay(.none);
        self.rail = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .height = S.rail_height }).mount(scope, cx);
        self.rail.container.setStyleInline(cx.allocator, S.viewport());
        self.rail.content.setStyleInline(cx.allocator, S.rail());
        self.rail.container.meta.ownership.meta.test_id = "ai.attachments.viewport";
        try self.root.appendChild(cx.allocator, self.rail.container);
        const guard = try scope.childScope();
        try guard.onCleanup(View, self, releaseFocus);
        try self.mountPreview();
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }

    /// Copies only the immutable ready references. Picker tickets are not
    /// attachments and never become fabricated processing/failed chips.
    pub fn update(self: *View, draft: ?*const attachments.Draft) !void {
        const current = if (self.pending_update) self.pending else self.source;
        const candidate = if (self.pending_update) self.pending_candidate else self.candidate;
        const readonly = if (self.pending_update) self.pending_readonly else self.readonly;
        if (!readonly and matches(current, draft) and candidateMatches(candidate, draft)) return;
        var next: ?attachments.Bundle = null;
        if (draft) |value| {
            const items = try self.cx.allocator.alloc(attachments.Item, value.items.items.len);
            for (value.items.items, items) |item, *copy| copy.* = .{ .id = item.id, .reference = item.reference.retain() };
            next = .{ .allocator = self.cx.allocator, .owner = value.owner, .draft_epoch = value.epoch, .items = items };
        }
        if (self.pending) |*previous| previous.deinit();
        if (self.pending_candidate) |*previous| previous.reference.release();
        self.pending = next;
        self.pending_candidate = null;
        if (draft) |value| if (value.candidates.items.len > 0) {
            const latest = value.candidates.items[value.candidates.items.len - 1];
            for (value.pending.items) |ticket| if (ticket.id == latest.id) {
                self.pending_candidate = .{ .ticket = ticket, .reference = latest.reference.retain() };
                break;
            };
        };
        self.pending_readonly = false;
        self.pending_update = true;
        self.cx.requestRedraw();
    }

    /// History views retain original sent refs and expose no draft mutations.
    pub fn updateSent(self: *View, bundle: *const attachments.Bundle) !void {
        const next = try bundle.retain();
        if (self.pending) |*previous| previous.deinit();
        if (self.pending_candidate) |*previous| previous.reference.release();
        self.pending = next;
        self.pending_candidate = null;
        self.pending_readonly = true;
        self.pending_update = true;
        self.cx.requestRedraw();
    }

    pub fn height(self: *const View) f32 {
        const current = if (self.pending_update) self.pending else self.source;
        return if (self.external_count > 0 or (current != null and current.?.items.len > 0)) S.rail_height + S.input_gap else 0;
    }

    pub fn openPreview(self: *View, id: attachments.Id) !void {
        const source = self.source orelse return error.StaleAttachment;
        for (source.items) |item| if (item.id == id) return self.openCaptured(itemTicket(source, item));
        return error.StaleAttachment;
    }

    pub fn dismiss(self: *View) void {
        if (!self.isPreviewOpen() and self.preview_ticket == null) return;
        if (self.popup) |popup| popup.open.?.set(false) else {
            self.inline_open = false;
            if (self.modal_open) |open| open.set(false) else self.preview_panel.setDisplay(.none);
            if (self.callbacks.preview_visibility) |callback| callback(self.callbacks.context, false);
        }
        self.closed();
    }

    pub fn isPreviewOpen(self: *const View) bool {
        return if (self.popup) |popup| popup.open.?.peek() else self.inline_open;
    }

    pub fn escapePreview(self: *View) bool {
        if (!self.isPreviewOpen()) return false;
        self.closePreview();
        return true;
    }

    pub fn openSentPreview(self: *View, ticket: attachments.Ticket, reference: attachments.ContentRef) !void {
        try self.showPreview(ticket, reference, .history);
    }

    pub fn restoreCandidate(self: *View, owner: attachments.Owner) !void {
        const candidate = (if (self.pending_update) self.pending_candidate else self.candidate) orelse return;
        if (!candidate.ticket.owner.eql(owner)) return;
        try self.openCaptured(candidate.ticket);
    }

    fn mountPreview(self: *View) !void {
        const cx = self.cx;
        const scope = try self.scope.childScope();
        self.preview_scope = scope;
        self.modal_open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = self.modal_open.?, .width = 480, .max_height = @max(200, cx.viewport.height - 32), .background = S.theme.current().overlay, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.modal = modal;
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        self.preview_panel = modal.dialog;
        modal.dialog.meta.ownership.meta.test_id = "ai.attachment.preview";
        modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = 480 }, .height = .{ .fit = .{} }, .padding = ui.Padding.all(1), .background = S.theme.current().overlay, .border = .{ .width = 1, .color = S.theme.current().border, .radius = 14 } });
        modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{}, .gap = 0, .direction = .column });
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 79.1484375 }, .padding = .{ .top = 20, .left = 22, .right = 22, .bottom = 16 }, .gap = 12, .direction = .row, .align_items = .start, .flex_shrink = 0 }, .{});
        heading.meta.ownership.meta.test_id = "ai.attachment.preview.header";
        try modal.body.appendChild(cx.allocator, heading);
        const titles = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 5, .min_width = 0 }, .{});
        try heading.appendChild(cx.allocator, titles);
        self.preview_title = try ui.text(cx, "上下文附件", .{ .font_size = 15, .font_weight = 700, .line_height = 20.0 / 15.0, .color = S.theme.current().fg_1 });
        try titles.appendChild(cx.allocator, self.preview_title);
        self.preview_identity = try ui.text(cx, "", .{ .font_size = 11, .line_height = 1.65, .color = S.theme.current().fg_2, .text_overflow = .ellipsis });
        self.preview_identity.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 18.1484375 } });
        self.preview_identity.meta.ownership.meta.test_id = "ai.attachment.preview.path";
        try titles.appendChild(cx.allocator, self.preview_identity);
        const close = try self.previewButton(scope, heading, "ai.attachment.preview.close", "关闭预览", ui.icons.x, closePreview);
        close.setStyleInline(cx.allocator, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 } });
        const body = try ui.box(cx, .{ .width = .fill(), .direction = .column, .padding = .{ .left = 22, .right = 22, .bottom = 20 }, .flex_shrink = 0 }, .{});
        self.modal_body = body;
        body.meta.ownership.meta.test_id = "ai.attachment.preview.body";
        try modal.body.appendChild(cx.allocator, body);
        const card = try ui.box(cx, .{ .width = .fill(), .padding = ui.Padding.all(14), .direction = .column, .background = S.theme.current().surface_2, .corner_radius = 11, .flex_shrink = 0 }, .{});
        self.modal_card = card;
        self.preview_identity_box = card;
        try body.appendChild(cx.allocator, card);
        const status = try ui.box(cx, .{ .height = .{ .px = 18 }, .width = .fill(), .direction = .row }, .{});
        try card.appendChild(cx.allocator, status);
        const badge = try ui.text(cx, "ready", .{ .font_size = 10, .line_height = 1.2, .color = S.theme.current().fg_2 });
        badge.setStyleInline(cx.allocator, .{ .height = .{ .px = 18 }, .padding = .{ .top = 3, .bottom = 3, .left = 6, .right = 6 }, .background = S.theme.current().well, .corner_radius = 5 });
        try status.appendChild(cx.allocator, badge);
        self.preview_metadata = try ui.text(cx, "", .{ .font_size = 12, .line_height = 1.65, .color = S.theme.current().fg_2, .wrap = .word });
        self.preview_metadata.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 19.796875 } });
        try card.appendChild(cx.allocator, self.preview_metadata);
        self.preview_info_text = try scope.createText("", .{});
        self.preview_info = try ui.box(cx, .{ .display = .none }, .{});
        try card.appendChild(cx.allocator, self.preview_info);
        self.preview_icons[0] = try ui.box(cx, .{ .display = .none }, .{});
        self.preview_icons[1] = try ui.box(cx, .{ .display = .none }, .{});
        self.preview_terminal_icon = try ui.box(cx, .{ .display = .none }, .{});
        // Empty compatibility handles belong to the existing info subtree;
        // the preview portal owns their lifetime and they retain zero size.
        try self.preview_info.appendChild(cx.allocator, self.preview_icons[0]);
        try self.preview_info.appendChild(cx.allocator, self.preview_icons[1]);
        try self.preview_info.appendChild(cx.allocator, self.preview_terminal_icon);
        self.preview_body = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = 41.796875 }).mount(scope, cx);
        self.preview_body.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 41.796875 }, .padding = .{ .top = 11, .bottom = 11 }, .flex_shrink = 0 });
        self.preview_body.container.meta.ownership.meta.test_id = "ai.attachment.preview.viewport";
        try card.appendChild(cx.allocator, self.preview_body.container);
        self.preview_label = try ui.text(cx, "", .{ .font_size = 11, .line_height = 1.8, .use_monospace_font = true, .color = S.theme.current().fg_1, .wrap = .word });
        self.preview_label.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
        self.preview_label.meta.ownership.meta.test_id = "ai.attachment.preview.text";
        try self.preview_body.content.appendChild(cx.allocator, self.preview_label);
        const footer = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 63.5 }, .padding = .{ .top = 15, .bottom = 14, .left = 22, .right = 22 }, .direction = .row, .align_items = .center, .justify = .end, .gap = 8, .background = S.theme.current().surface_1, .flex_shrink = 0 }, .{});
        footer.meta.ownership.meta.test_id = "ai.attachment.preview.footer";
        try modal.body.appendChild(cx.allocator, footer);
        self.preview_reselect = try self.previewButton(scope, footer, "ai.attachment.preview.reselect", "重新选择本地文本", ui.icons.get("folder-open").?, reselectPreview);
        self.preview_remove = try self.previewButton(scope, footer, "ai.attachment.preview.remove", "移除附件", ui.icons.x, removePreview);
        self.preview_primary = try ui.widgets.Button(.{ .label = "关闭", .variant = .primary, .base_style = @as(ui.BoxStyle, .{ .width = .{ .px = 52 }, .height = .{ .px = 34.5 }, .padding = .{ .left = 14, .right = 14, .top = 9, .bottom = 9 }, .font_size = 12, .font_weight = 500, .corner_radius = 8 }), .on_click = cx.on(View, self, confirmPreview) }).mount(scope, cx);
        self.preview_primary.meta.ownership.meta.test_id = "ai.attachment.preview.keep";
        try footer.appendChild(cx.allocator, self.preview_primary);
        self.preview_primary_check = try ui.box(cx, .{ .display = .none }, .{});
        try self.preview_info.appendChild(cx.allocator, self.preview_primary_check);
        self.preview_primary_plus = try ui.iconTint(cx, ui.icons.plus, S.theme.current().fg_2, icon(17));
        self.preview_primary_plus.setDisplay(.none);
        try self.preview_primary.appendChild(cx.allocator, self.preview_primary_plus);
    }

    fn setButtonCopy(cx: *ui.Cx, node: *ui.Node, copy: []const u8) void {
        if (node.getText() != null) {
            node.setTextContent(cx.allocator, copy) catch {};
            return;
        }
        for (node.children.items) |child| setButtonCopy(cx, child, copy);
    }
    fn previewButton(self: *View, scope: *ui.Scope, parent: *ui.Node, test_id: []const u8, label: []const u8, asset: ui.SvgAsset, comptime action: *const fn (*View) void) !*ui.Node {
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = label, .base_style = self.icon_style, .hover_style = self.icon_hover, .on_click = self.cx.on(View, self, action) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = test_id;
        const image = try ui.iconTint(self.cx, asset, S.theme.current().fg_2, icon(S.icon_size));
        try button.appendChild(self.cx.allocator, image);
        button.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .padding = .{} });
        // The close and keep/remove icons are recolored by walking actual
        // icon nodes during theme refresh, not by mounting another window.
        try parent.appendChild(self.cx.allocator, button);
        return button;
    }

    fn buildCard(self: *View, scope: *ui.Scope, source: attachments.Bundle, item: attachments.Item) !void {
        const content = item.reference.content() orelse return error.EmptyAttachmentResult;
        try self.cards.ensureUnusedCapacity(self.cx.allocator, 1);
        const state = try scope.createState(Card, .{ .view = self, .ticket = itemTicket(source, item), .remove_style = try scope.createSignal(S.ButtonStyle, S.iconButton()), .preview_style = try scope.createSignal(S.ButtonStyle, S.previewButton()), .hover_style = try scope.createSignal(?ui.BoxStyle, S.hover()), .removing = try scope.createSignal(bool, false) });
        const card = try ui.boxStyled(self.cx, S.card, .{});
        errdefer self.cx.destroyDetached(card);
        state.root = card;
        card.meta.ownership.meta.test_id = if (content.source == .terminal) "ai.attachment.terminal_text" else if (content.source == .remote_file) "ai.attachment.remote_file" else "ai.attachment.local_text";
        state.preview = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = if (content.source == .terminal) "预览终端文本" else if (content.source == .remote_file) "预览远程文件" else "预览本地文本", .base_style = state.preview_style, .hover_style = state.hover_style, .on_click = self.cx.on(Card, state, Card.open) }).mount(scope, self.cx);
        state.preview.setStyleInline(self.cx.allocator, S.previewSlot());
        state.preview.meta.ownership.meta.test_id = "ai.attachment.open";
        state.icons[0] = try ui.iconTint(self.cx, if (content.source == .terminal) ui.icons.terminal else ui.icons.get("file-text").?, S.theme.current().accent, icon(S.icon_size));
        try state.preview.appendChild(self.cx.allocator, state.icons[0]);
        try card.appendChild(self.cx.allocator, state.preview);
        const name_hint = try ui.widgets.Tooltip(.{ .text = content.path }).mount(scope, self.cx);
        name_hint.wrapper.setStyleInline(self.cx.allocator, S.filenameSlot());
        name_hint.trigger.setStyleInline(self.cx.allocator, S.filenameTrigger());
        const filename = try ui.textStyled(self.cx, S.filename, std.fs.path.basename(content.path));
        state.filename = filename;
        filename.setStyleInline(self.cx.allocator, S.filenameTrigger());
        filename.meta.ownership.meta.test_id = "ai.attachment.filename";
        try name_hint.trigger.appendChild(self.cx.allocator, filename);
        try state.preview.appendChild(self.cx.allocator, name_hint.wrapper);
        var buffer: [80]u8 = undefined;
        const metadata = try ui.textStyled(self.cx, S.metadata, "");
        state.metadata = metadata;
        try metadata.setTextContent(self.cx.allocator, switch (content.source) {
            .local_file => try std.fmt.bufPrint(&buffer, "本地 · {d} B", .{content.bytes.len}),
            .remote_file => |remote| try std.fmt.bufPrint(&buffer, "#{d} · {d} B · {s}", .{ @backingInt(remote.owner.session_id), content.bytes.len, if (remote.truncated) "已截断" else "完整" }),
            .terminal => |terminal| try std.fmt.bufPrint(&buffer, "#{d} · {d} B · {d} 行", .{ @backingInt(terminal.owner.session_id), content.bytes.len, terminal.line_count }),
        });
        metadata.setStyleInline(self.cx.allocator, S.metadataSlot());
        metadata.meta.ownership.meta.test_id = "ai.attachment.metadata";
        try card.appendChild(self.cx.allocator, metadata);
        const remove = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = if (content.source == .terminal) "移除终端文本附件" else "移除本地文本附件", .base_style = state.remove_style, .hover_style = state.hover_style, .disabled = state.removing, .on_click = self.cx.on(Card, state, Card.remove) }).mount(scope, self.cx);
        remove.setStyleInline(self.cx.allocator, S.removeSlot());
        remove.meta.ownership.meta.test_id = "ai.attachment.remove";
        remove.setDisplay(if (self.readonly or self.callbacks.remove == null) .none else .flex);
        state.icons[1] = try ui.iconTint(self.cx, ui.icons.x, S.theme.current().fg_2, icon(S.icon_size));
        try remove.appendChild(self.cx.allocator, state.icons[1]);
        try card.appendChild(self.cx.allocator, remove);
        try self.rail.content.appendChild(self.cx.allocator, card);
        self.cards.appendAssumeCapacity(state);
    }

    fn openCaptured(self: *View, ticket: attachments.Ticket) !void {
        if (!self.contains(ticket)) return error.StaleAttachment;
        // restoreCandidate may run immediately after update, before afterLayout
        // applies the projection. Validate and resolve against that same view.
        const candidate = if (self.pending_update) self.pending_candidate else self.candidate;
        if (candidate) |selected| if (selected.ticket.eql(ticket)) {
            return self.showPreview(ticket, selected.reference, .candidate);
        };
        const source = (if (self.pending_update) self.pending else self.source) orelse return error.StaleAttachment;
        const readonly = if (self.pending_update) self.pending_readonly else self.readonly;
        for (source.items) |item| if (item.id == ticket.id) {
            if (readonly) if (self.callbacks.preview_sent) |callback| return callback(self.callbacks.context, ticket, item.reference);
            return self.showPreview(ticket, item.reference, if (readonly) .history else .draft);
        };
        return error.StaleAttachment;
    }
    fn showPreview(self: *View, ticket: attachments.Ticket, reference: attachments.ContentRef, kind: PreviewKind) !void {
        const content = reference.content() orelse return error.EmptyAttachmentResult;
        try self.preview_identity.setTextContent(self.cx.allocator, content.path);
        const metadata = switch (content.source) {
            .local_file => try std.fmt.allocPrint(self.cx.allocator, "本地 · {s} · {d} B · 完整", .{ if (content.bom_preserved) "UTF-8 BOM" else "UTF-8", content.bytes.len }),
            .remote_file => |remote| try std.fmt.allocPrint(self.cx.allocator, "{s} · 会话 #{d} · {d} B · {s}", .{ remote.source_name, @backingInt(remote.owner.session_id), content.bytes.len, if (remote.truncated) "已截断" else "完整" }),
            .terminal => |terminal| try std.fmt.allocPrint(self.cx.allocator, "{s} #{d} · {d} 行 · {d} B", .{ terminal.source_name, @backingInt(terminal.owner.session_id), terminal.line_count, content.bytes.len }),
        };
        defer self.cx.allocator.free(metadata);
        try self.preview_metadata.setTextContent(self.cx.allocator, metadata);
        try self.preview_title.setTextContent(self.cx.allocator, "上下文附件");
        var time_buffer: [8]u8 = undefined;
        const capture_time = try @import("terminal_surface_input.zig").localTimestamp(&time_buffer, content.captured_at_ms);
        var info_buffer: [40]u8 = undefined;
        self.preview_info_text.set(try std.fmt.bufPrint(&info_buffer, "捕获 {s}", .{capture_time}));
        self.preview_info.setDisplay(if (content.source == .terminal) .flex else .none);
        self.preview_icons[0].setDisplay(if (content.source == .terminal) .none else .flex);
        self.preview_terminal_icon.setDisplay(if (content.source == .terminal) .flex else .none);
        try self.preview_label.setTextContent(self.cx.allocator, content.bytes);
        const line_count = @max(1, std.mem.count(u8, content.bytes, "\n") + 1);
        const preview_h = @min(@max(41.796875, @as(f32, @floatFromInt(line_count)) * 19.8 + 22), @max(41.796875, self.cx.viewport.height - 260));
        self.preview_body.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = preview_h } });
        self.preview_reference.release();
        self.preview_reference = reference.retain();
        self.preview_ticket = ticket;
        self.preview_kind = kind;
        self.preview_body.state.scroll_y = 0;
        if (self.preview_primary.behavior.interaction.a11y) |*attrs| attrs.label = switch (kind) {
            .candidate => switch (content.source) {
                .local_file => "附加本地文本",
                .remote_file => "附加远程文件",
                .terminal => |terminal| if (terminal.origin == .selection) "附加终端选区" else "附加命令上下文",
            },
            .draft => "保留附加",
            .history => "关闭预览",
        };
        self.preview_primary.setStyleInline(self.cx.allocator, .{ .width = .{ .px = if (kind == .candidate) 88 else 52 } });
        setButtonCopy(self.cx, self.preview_primary, if (kind == .candidate) "附加快照" else "关闭");
        const candidate_plus = false;
        self.preview_primary_plus.setDisplay(if (candidate_plus) .flex else .none);
        self.preview_primary_check.setDisplay(if (candidate_plus) .none else .flex);
        self.preview_remove.setDisplay(if (kind == .history or self.callbacks.remove == null) .none else .flex);
        self.preview_reselect.setDisplay(if (kind == .history or content.source != .local_file or self.callbacks.reselect == null) .none else .flex);
        if (self.popup) |popup| popup.open.?.set(true) else {
            self.inline_open = true;
            if (self.modal_open) |open| open.set(true) else self.preview_panel.setDisplay(.flex);
            if (self.callbacks.preview_visibility) |callback| callback(self.callbacks.context, true);
            self.cx.setFocus(self.preview_primary);
        }
        self.cx.requestRedraw();
    }
    fn contains(self: *const View, ticket: attachments.Ticket) bool {
        const source = (if (self.pending_update) self.pending else self.source) orelse return false;
        if (!source.owner.eql(ticket.owner) or source.draft_epoch != ticket.draft_epoch) return false;
        const candidate = if (self.pending_update) self.pending_candidate else self.candidate;
        if (candidate) |value| if (value.ticket.eql(ticket)) return true;
        for (source.items) |item| if (item.id == ticket.id) return true;
        return false;
    }
    fn closePreview(self: *View) void {
        if (self.preview_kind == .candidate) if (self.preview_ticket) |ticket| if (self.contains(ticket)) {
            if (self.callbacks.remove) |callback| callback(self.callbacks.context, ticket) catch |err| self.fail(err);
        };
        self.dismiss();
    }
    fn confirmPreview(self: *View) void {
        if (self.preview_kind == .candidate) {
            const ticket = self.preview_ticket orelse return;
            if (!self.contains(ticket)) return;
            const callback = self.callbacks.attach orelse return;
            callback(self.callbacks.context, ticket) catch |err| {
                self.fail(err);
                return;
            };
        }
        self.dismiss();
    }
    fn reselectPreview(self: *View) void {
        const ticket = self.preview_ticket orelse return;
        if (self.preview_kind == .history or !self.contains(ticket)) return;
        const callback = self.callbacks.reselect orelse return;
        callback(self.callbacks.context, ticket) catch |err| self.fail(err);
    }
    fn removePreview(self: *View) void {
        const ticket = self.preview_ticket orelse return;
        if (!self.contains(ticket)) return;
        const callback = self.callbacks.remove orelse return;
        callback(self.callbacks.context, ticket) catch |err| {
            self.fail(err);
            return;
        };
        self.dismiss();
    }
    fn closed(self: *View) void {
        const ticket = self.preview_ticket;
        self.preview_ticket = null;
        self.preview_kind = null;
        self.preview_reference.release();
        if (self.cx.focus_manager.current_focus) |node| if (node.isDescendantOf(self.preview_panel)) {
            for (self.cards.items) |card| if (ticket != null and card.ticket.eql(ticket.?)) {
                self.cx.setFocus(card.preview);
                return;
            };
            self.cx.clearFocus();
        };
    }
    fn openChanged(self: *View, open: bool) void {
        if (!open) self.closePreview();
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.height() > 0) {
            const r = self.rail.container.globalRect();
            return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        }
        const r = self.root.globalRect();
        return .{ .x = r.x + 14, .y = r.y, .w = @max(0, r.w - 28), .h = 0 };
    }
    fn fail(self: *View, err: anyerror) void {
        self.last_error = err;
        if (self.callbacks.on_error) |callback| callback(self.callbacks.context, err);
    }
    fn clearCards(self: *View) void {
        if (self.cx.pressed_node) |node| if (node.isDescendantOf(self.rail.content)) self.cx.cancelPointerInteractions(.explicit);
        if (self.cx.focus_manager.current_focus) |node| if (node.isDescendantOf(self.rail.content)) self.cx.clearFocus();
        var index: usize = 0;
        while (index < self.rail.content.children.items.len) {
            const node = self.rail.content.children.items[index];
            if (node == self.external_rail) {
                index += 1;
                continue;
            }
            self.cx.detachChild(self.rail.content, node);
            self.cx.destroyDetached(node);
        }
        if (self.cards_scope) |scope| scope.dispose();
        self.cards_scope = null;
        self.cards.clearRetainingCapacity();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        const changed = self.pending_update;
        if (changed) {
            const old_candidate = if (self.candidate) |value| value.ticket else null;
            // A sent projection changes the available actions even when the
            // immutable ticket is unchanged. Do not leave a candidate modal
            // above the newly read-only chip with its former attach action.
            if (self.pending_readonly != self.readonly) self.dismiss();
            if (self.preview_ticket) |ticket| {
                if (self.preview_kind == .history) {
                    if (self.pending == null or !self.pending.?.owner.eql(ticket.owner)) self.dismiss();
                } else if (!self.contains(ticket)) self.dismiss();
            }
            self.clearCards();
            if (self.source) |*old| old.deinit();
            self.source = self.pending;
            if (self.candidate) |*previous| previous.reference.release();
            self.candidate = self.pending_candidate;
            self.pending_candidate = null;
            self.readonly = self.pending_readonly;
            self.pending = null;
            self.pending_update = false;
            self.cards_scope = self.scope.childScope() catch |err| {
                self.fail(err);
                return .done;
            };
            if (self.source) |source| for (source.items) |item| self.buildCard(self.cards_scope.?, source, item) catch |err| {
                self.fail(err);
                break;
            };
            if (self.candidate) |candidate| if (old_candidate == null or !old_candidate.?.eql(candidate.ticket)) self.openCaptured(candidate.ticket) catch |err| self.fail(err);
        }
        const themed = !std.meta.eql(self.colors, S.theme.current());
        if (themed) {
            self.colors = S.theme.current();
            self.icon_style.set(S.iconButton());
            self.icon_hover.set(S.hover());
            for (self.cards.items) |card| card.retheme();
            self.preview_panel.setBackground(S.theme.current().overlay);
            self.preview_title.setTextColor(self.colors.fg_1);
            self.preview_identity_box.setBackground(self.colors.well);
            self.preview_identity.setTextColor(self.colors.fg_1);
            self.preview_metadata.setTextColor(self.colors.fg_2);
            self.preview_label.setTextColor(self.colors.fg_1);
            tintIcons(self.preview_panel);
            _ = self.preview_icons[0].setTint(S.theme.current().accent);
            _ = self.preview_terminal_icon.setTint(S.theme.current().accent);
        }
        const row_height = self.height();
        if (self.modal == null and self.inline_parent != null) self.preview_panel.setDisplay(if (self.inline_open) .flex else .none);
        self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .px = if (row_height > 0) row_height - 4 else 0 } });
        self.rail.container.setDisplay(if (row_height > 0) .flex else .none);
        self.root.setDisplay(if (row_height > 0 or (self.candidate != null and self.inline_parent == null)) .flex else .none);
        var parent = self.root.parent;
        while (parent) |node| : (parent = node.parent) if (node.style.display == .none) {
            self.dismiss();
            break;
        };
        return if (changed or themed) .needs_layout else .done;
    }
    fn releaseFocus(self: *View) void {
        if (self.cx.focus_manager.current_focus) |node| if (node.isDescendantOf(self.root) or node.isDescendantOf(self.preview_panel)) self.cx.clearFocus();
    }
    fn release(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.inline_parent) |parent| if (self.modal == null) {
            self.cx.detachChild(parent, self.preview_panel);
            self.cx.destroyDetached(self.preview_panel);
        };
        self.preview_reference.release();
        if (self.candidate) |*value| value.reference.release();
        if (self.pending_candidate) |*value| value.reference.release();
        if (self.pending) |*source| source.deinit();
        if (self.source) |*source| source.deinit();
        self.cards.deinit(self.cx.allocator);
    }
};
fn candidateMatches(value: ?View.Candidate, draft: ?*const attachments.Draft) bool {
    const source = draft orelse return value == null;
    if (source.candidates.items.len == 0) return value == null;
    const previous = value orelse return false;
    const current = source.candidates.items[source.candidates.items.len - 1];
    for (source.pending.items) |ticket| if (ticket.id == current.id) return previous.ticket.eql(ticket);
    return false;
}
fn itemTicket(source: attachments.Bundle, item: attachments.Item) attachments.Ticket {
    const content = item.reference.content().?;
    return .{ .owner = source.owner, .draft_epoch = source.draft_epoch, .id = item.id, .terminal_owner = if (content.source == .terminal) content.source.terminal.owner else null };
}
fn matches(bundle: ?attachments.Bundle, draft: ?*const attachments.Draft) bool {
    const value = draft orelse return bundle == null;
    const previous = bundle orelse return false;
    if (!previous.owner.eql(value.owner) or previous.draft_epoch != value.epoch or previous.items.len != value.items.items.len) return false;
    for (previous.items, value.items.items) |old, current| {
        if (old.id != current.id) return false;
        const before = old.reference.content() orelse return false;
        const after = current.reference.content() orelse return false;
        if (before.bytes.ptr != after.bytes.ptr) return false;
    }
    return true;
}
fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size } };
}
fn tintIcons(node: *ui.Node) void {
    if (node.getIcon()) |_| _ = node.setTint(S.theme.current().fg_2);
    for (node.children.items) |child| tintIcons(child);
}
