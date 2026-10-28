//! Frozen conflict decisions only. The host owns re-stat, authorization, IO,
//! pause and receipts. Selecting a radio never dispatches a transfer decision.
const std = @import("std");
const ui = @import("ui");
const transfer = @import("../transfer/manager.zig");
pub const Conflict = transfer.Conflict;
pub const domain = @import("../transfer/conflict.zig");
const Name = @import("../host/directory_name.zig");
const S = @import("transfer_conflict_styles.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    /// Request strings borrow the View until this callback returns.
    decision: *const fn (*anyopaque, Conflict.Request) anyerror!void,
    defer_conflict: *const fn (*anyopaque, domain.Key) anyerror!void,
};
const values = [_][]const u8{ "skip", "save_as", "keep_both", "overwrite" };
const ids = [_][]const u8{ "transfer.conflict.skip", "transfer.conflict.save_as", "transfer.conflict.keep_both", "transfer.conflict.overwrite" };
const options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = values[0], .label = "跳过", .test_id = ids[0] },
    .{ .value = values[1], .label = "另存为", .test_id = ids[1] },
    .{ .value = values[2], .label = "双方保留", .test_id = ids[2] },
    .{ .value = values[3], .label = "覆盖", .test_id = ids[3] },
};

pub const View = struct {
    cx: *ui.Cx,
    callbacks: Callbacks,
    root: *ui.Node,
    dialog: *ui.Node,
    form: *ui.Node,
    fade: *ui.Node,
    grip: *ui.Node,
    header: *ui.Node,
    title: *ui.Node,
    header_icon: *ui.Node,
    close: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult,
    choices: *ui.Node,
    caption: *ui.Node,
    target: *ui.Node,
    metadata: *ui.Node,
    radios: *ui.Node,
    rows: [4]*ui.Node,
    glyphs: [4]*ui.Node,
    labels: [4]*ui.Node,
    input: ui.widgets.input.InputResult,
    hint: *ui.Node,
    checkbox: *ui.Node,
    confirmation: *ui.Node,
    notice: *ui.Node,
    confirmation_heading: *ui.Node,
    confirmation_detail: *ui.Node,
    confirmation_paths: *ui.Node,
    confirmation_metadata: *ui.Node,
    confirmation_warning: *ui.Node,
    error_text: *ui.Node,
    footer: *ui.Node,
    pause: *ui.Node,
    back: *ui.Node,
    primary: *ui.Node,
    open: *ui.Signal(bool),
    selected: *ui.Signal(?[]const u8),
    rename: *ui.Signal([]const u8),
    apply_remaining: *ui.Signal(bool),
    disabled: *ui.Signal(bool),
    primary_disabled: *ui.Signal(bool),
    primary_style: *ui.Signal(ui.BoxStyle),
    back_style: *ui.Signal(ui.BoxStyle),
    primary_label: *ui.Signal([]const u8),
    primary_variant: *ui.Signal(ui.widgets.ButtonVariant),
    source: ?Conflict.OwnedSnapshot = null,
    draft_key: ?domain.Key = null,
    source_metadata: ?domain.Metadata = null,
    visible: bool = false,
    pending: bool = false,
    dirty: bool = false,
    focus_pending: bool = false,
    failure: ?anyerror = null,
    painted: ?S.theme.Colors = null,
    interaction_ready: bool = false,
    mode: S.Mode = .choice,
    viewport: ui.Size = .ZERO,

    /// Modal owns its portal; callers must not append root a second time.
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{
            .cx = cx,
            .callbacks = callbacks,
            .root = undefined,
            .dialog = undefined,
            .form = undefined,
            .fade = undefined,
            .grip = undefined,
            .header = undefined,
            .title = undefined,
            .header_icon = undefined,
            .close = undefined,
            .scroll = undefined,
            .choices = undefined,
            .caption = undefined,
            .target = undefined,
            .metadata = undefined,
            .radios = undefined,
            .rows = undefined,
            .glyphs = undefined,
            .labels = undefined,
            .input = undefined,
            .hint = undefined,
            .checkbox = undefined,
            .confirmation = undefined,
            .notice = undefined,
            .confirmation_heading = undefined,
            .confirmation_detail = undefined,
            .confirmation_paths = undefined,
            .confirmation_metadata = undefined,
            .confirmation_warning = undefined,
            .error_text = undefined,
            .footer = undefined,
            .pause = undefined,
            .back = undefined,
            .primary = undefined,
            .open = try scope.createSignal(bool, false),
            .selected = try scope.createSignal(?[]const u8, null),
            .rename = try scope.createText("", .{}),
            .apply_remaining = try scope.createSignal(bool, false),
            .disabled = try scope.createSignal(bool, true),
            .primary_disabled = try scope.createSignal(bool, true),
            .primary_style = try scope.createSignal(ui.BoxStyle, S.button(156, 30, true, false)),
            .back_style = try scope.createSignal(ui.BoxStyle, S.button(116, 30, false, false)),
            .primary_label = try scope.createText("应用选择", .{}),
            .primary_variant = try scope.createSignal(ui.widgets.ButtonVariant, .primary),
        };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        const modal = try ui.widgets.Modal(.{ .open = ui.split(self.open, cx.on(View, self, openChanged)), .width = S.width(.choice), .max_height = @max(0, cx.viewport.height - 16), .background = S.theme.current().overlay, .close_on_overlay = false }).mount(scope, cx);
        self.root = modal.overlay;
        self.interaction_ready = true;
        self.dialog = modal.dialog;
        self.form = modal.body;
        self.root.meta.ownership.meta.test_id = "transfer.conflict.overlay";
        self.dialog.meta.ownership.meta.test_id = "transfer.conflict";
        self.dialog.behavior.events.on_key_down = onKey;
        self.dialog.behavior.events.key_context = self;
        self.form.setStyleInline(cx.allocator, S.form());
        self.fade = try ui.box(cx, S.fade(), .{});
        try self.form.appendChild(cx.allocator, self.fade);
        const grip_row = try ui.box(cx, S.gripRow(), .{});
        self.grip = try ui.box(cx, S.grip(), .{});
        self.grip.meta.ownership.meta.test_id = "transfer.conflict.grip";
        try grip_row.appendChild(cx.allocator, self.grip);
        try self.form.appendChild(cx.allocator, grip_row);
        self.header = try ui.box(cx, S.header(.choice), .{});
        self.header_icon = try ui.iconTint(cx, ui.icons.files, S.theme.current().accent, S.icon(18));
        try self.header.appendChild(cx.allocator, self.header_icon);
        self.title = try ui.text(cx, "同名文件处理", S.title());
        try self.header.appendChild(cx.allocator, self.title);
        try self.header.appendChild(cx.allocator, try ui.spacer(cx));
        self.close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "暂不处理，暂停原任务", .base_style = S.iconButton(22), .hover_style = S.hover(), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        self.close.meta.ownership.meta.test_id = "transfer.conflict.close";
        try self.header.appendChild(cx.allocator, self.close);
        try self.form.appendChild(cx.allocator, self.header);
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.scroll.container.meta.ownership.meta.test_id = "transfer.conflict.viewport";
        self.scroll.container.setStyleInline(cx.allocator, S.viewport(.choice));
        self.scroll.content.setStyleInline(cx.allocator, S.stack(8));
        self.choices = try ui.box(cx, S.stack(8), .{});
        self.caption = try addText(cx, self.choices, "transfer.conflict.caption", S.caption(), 18);
        self.target = try addText(cx, self.choices, "transfer.conflict.target", S.path(), 17);
        self.metadata = try addText(cx, self.choices, "transfer.conflict.metadata", S.detail(), 17);
        self.radios = try ui.widgets.RadioGroup(.{ .options = &options, .value = self.selected, .disabled = self.disabled, .on_change = cx.on(View, self, chosen) }).mount(scope, cx);
        self.radios.setStyleInline(cx.allocator, S.stack(8));
        for (ids, 0..) |id, index| {
            const row = find(self.radios, id) orelse return error.ConflictOptionUnavailable;
            self.rows[index] = row;
            const circle = row.children.items[0];
            for (circle.children.items) |child| child.setDisplay(.none);
            circle.setStyleInline(cx.allocator, S.radioGlyph());
            self.glyphs[index] = try ui.iconTint(cx, ui.icons.circle, S.theme.current().fg_2, S.icon(16));
            try circle.appendChild(cx.allocator, self.glyphs[index]);
            self.labels[index] = row.children.items[1];
        }
        try self.choices.appendChild(cx.allocator, self.radios);
        self.input = try ui.widgets.Input(.{ .value = self.rename, .placeholder = "新的文件名", .disabled = self.disabled, .on_change = cx.on(View, self, renamed), .on_submit = cx.on(View, self, submitted) }).mountResult(scope, cx);
        @import("app_theme.zig").styleInput(self.input);
        self.input.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 31 }, .flex_shrink = 0 });
        self.input.input_container.setStyleInline(cx.allocator, S.input());
        self.input.input_container.meta.ownership.meta.test_id = "transfer.conflict.name";
        self.input.input_container.behavior.interaction.a11y.?.label = "另存文件名";
        try self.choices.appendChild(cx.allocator, self.input.node);
        self.hint = try addText(cx, self.choices, "transfer.conflict.hint", S.detail(), 17);
        self.checkbox = try ui.widgets.Checkbox(.{ .checked = self.apply_remaining, .label = "仅对本队列剩余同名文件应用此选择", .box_size = @as(f32, 16), .label_font_size = @as(f32, 10.5), .disabled = self.disabled, .on_change = cx.on(View, self, applyRemainingChanged) }).mount(scope, cx);
        self.checkbox.setStyleInline(cx.allocator, S.checkbox());
        self.checkbox.meta.ownership.meta.test_id = "transfer.conflict.remaining";
        try self.choices.appendChild(cx.allocator, self.checkbox);
        try self.scroll.content.appendChild(cx.allocator, self.choices);
        self.confirmation = try ui.box(cx, S.stack(10), .{});
        self.notice = try ui.box(cx, S.notice(), .{});
        self.confirmation_heading = try addText(cx, self.notice, "transfer.conflict.confirm.heading", S.caption(), 18);
        self.confirmation_detail = try addText(cx, self.notice, "transfer.conflict.confirm.detail", S.text(11, 400, false, 16), 16);
        try self.confirmation.appendChild(cx.allocator, self.notice);
        self.confirmation_paths = try addText(cx, self.confirmation, "transfer.conflict.confirm.paths", S.path(), 60);
        self.confirmation_metadata = try addText(cx, self.confirmation, "transfer.conflict.confirm.metadata", S.text(11.5, 400, false, 18), 18);
        self.confirmation_warning = try addText(cx, self.confirmation, "transfer.conflict.confirm.warning", S.text(10.5, 400, false, 18), 18);
        try self.scroll.content.appendChild(cx.allocator, self.confirmation);
        self.error_text = try addText(cx, self.scroll.content, "transfer.conflict.error", S.detail(), 17);
        try self.form.appendChild(cx.allocator, self.scroll.container);
        self.footer = try ui.box(cx, S.footer(.choice), .{});
        self.footer.meta.ownership.meta.test_id = "transfer.conflict.footer";
        try self.footer.appendChild(cx.allocator, try ui.spacer(cx));
        self.pause = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.pause, .icon_size = @as(f32, 16), .a11y_label = "暂不处理，暂停原任务", .base_style = S.iconButton(28), .hover_style = S.hover(), .disabled = self.disabled, .on_click = cx.on(View, self, postpone) }).mount(scope, cx);
        self.pause.meta.ownership.meta.test_id = "transfer.conflict.pause";
        try self.footer.appendChild(cx.allocator, self.pause);
        self.back = try ui.widgets.Button(.{ .variant = .secondary, .label = "返回选择", .base_style = self.back_style, .disabled = self.disabled, .on_click = cx.on(View, self, returnToChoice) }).mount(scope, cx);
        self.back.meta.ownership.meta.test_id = "transfer.conflict.back";
        try self.footer.appendChild(cx.allocator, self.back);
        self.primary = try ui.widgets.Button(.{ .variant = self.primary_variant, .label = self.primary_label, .base_style = self.primary_style, .disabled = self.primary_disabled, .on_click = cx.on(View, self, submit) }).mount(scope, cx);
        self.primary.meta.ownership.meta.test_id = "transfer.conflict.apply";
        try self.footer.appendChild(cx.allocator, self.primary);
        try self.form.appendChild(cx.allocator, self.footer);
        self.choices.setDisplay(.none);
        self.confirmation.setDisplay(.none);
        self.error_text.setDisplay(.none);
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, self.root);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }

    /// Copies all borrowed paths before returning. Same-key polling preserves
    /// the editable draft. A new revision invalidates old pointer approval.
    pub fn show(self: *View, value: Conflict.Snapshot) !void {
        try validate(value);
        const next_key = keyOf(value);
        const current = if (self.source) |owned| owned.value else null;
        const same = if (current) |old| sameCapture(old, value) else false;
        if (current) |old| try rejectOld(old, value);
        if (current) |old| if (snapshotEqual(old, value)) {
            if (!self.visible) {
                self.visible = true;
                self.open.set(true);
                self.focus_pending = true;
                self.dirty = true;
            }
            try self.flush();
            return;
        };
        var owned = try Conflict.OwnedSnapshot.clone(self.cx.allocator, value);
        var consumed = false;
        errdefer if (!consumed) owned.deinit();
        const changed_stage = current == null or std.meta.activeTag(current.?.pending) != std.meta.activeTag(value.pending);
        const changed_ticket = current != null and current.?.pending == .overwrite_confirmation and value.pending == .overwrite_confirmation and !std.meta.eql(current.?.pending.overwrite_confirmation.ticket, value.pending.overwrite_confirmation.ticket);
        if (!same or changed_stage or changed_ticket) self.cancelOldInteraction();
        if (!same) {
            self.selected.set(null);
            self.rename.set("");
            self.apply_remaining.set(false);
            self.source_metadata = null;
            self.draft_key = next_key;
            self.failure = null;
            self.pending = false;
            self.focus_pending = true;
            ui.widgets.setScrollY(self.scroll.state, self.scroll.content, 0);
        } else if (changed_stage or changed_ticket) {
            self.pending = false;
            self.failure = null;
        }
        switch (value.pending) {
            .choice => |prompt| {
                if (!same) {
                    self.selected.set(if (prompt.selection.choice) |selection| values[@backingInt(selection)] else null);
                    self.rename.set(prompt.selection.rename);
                    self.apply_remaining.set(prompt.selection.apply_to_remaining);
                }
                self.source_metadata = prompt.source_metadata;
                self.draft_key = prompt.key;
                if (prompt.issue != null or value.issue != null) self.pending = false;
            },
            .context_required => self.pending = false,
            .overwrite_confirmation => {},
        }
        if (self.source) |*old| old.deinit();
        self.source = owned;
        consumed = true;
        self.visible = true;
        self.dirty = true;
        self.open.set(true);
        try self.flush();
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.cancelOldInteraction();
        self.visible = false;
        self.focus_pending = false;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    pub fn isVisible(self: *const View) bool {
        return self.visible;
    }
    pub fn setError(self: *View, key: domain.Key, cause: anyerror) bool {
        const current = if (self.source) |owned| keyOf(owned.value) else return false;
        if (current == null or !std.meta.eql(current.?, key)) return false;
        self.failure = cause;
        self.pending = false;
        self.dirty = true;
        self.cx.requestRedraw();
        return true;
    }
    pub fn retheme(self: *View) !void {
        self.dirty = true;
        try self.flush();
    }
    pub fn flush(self: *View) !void {
        if (!self.visible or self.source == null) return;
        if (self.painted == null or !std.meta.eql(self.painted.?, S.theme.current())) self.dirty = true;
        if (self.dirty) {
            self.dirty = false;
            try self.refresh();
        }
        self.syncLayout();
    }
    fn syncLayout(self: *View) void {
        self.viewport = self.cx.viewport;
        const style = S.panel(self.mode, self.viewport, self.scroll.content.globalRect().h);
        if (!std.meta.eql(self.form.style.padding, ui.Padding.ZERO)) self.form.setStyleInline(self.cx.allocator, S.form());
        if (!std.meta.eql(self.dialog.style.width, style.width.?) or !std.meta.eql(self.dialog.style.height, style.height.?)) self.dialog.setStyleInline(self.cx.allocator, style);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.visible) return .done;
        const old = self.dialog.globalRect();
        const padded = !std.meta.eql(self.form.style.padding, ui.Padding.ZERO);
        self.flush() catch {};
        if (self.focus_pending) {
            self.focus_pending = false;
            self.cx.setFocus(self.close);
        }
        if (padded or self.dialog.style.width.px != old.w or self.dialog.style.height.px != old.h) return .needs_layout;
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cancelOldInteraction();
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.deinit();
        self.cx.allocator.destroy(self);
    }
    fn cancelOldInteraction(self: *View) void {
        if (!self.interaction_ready) return;
        if (self.cx.pressed_node) |node| if (node == self.root or node.isDescendantOf(self.root)) self.cx.cancelPointerInteractions(.explicit);
        if (self.cx.focused_node) |node| if (node == self.root or node.isDescendantOf(self.root)) self.cx.clearFocus();
    }
    fn openChanged(self: *View, open_: bool) void {
        if (!open_ and self.visible) self.dismiss();
    }
    fn chosen(self: *View, _: []const u8) void {
        if (!self.visible or self.pending) return;
        self.failure = null;
        self.dirty = true;
        self.flush() catch {};
        if (self.choice() == .save_as) self.cx.setFocus(self.input.input_container);
    }
    fn renamed(self: *View, _: []const u8) void {
        if (!self.visible or self.pending) return;
        self.failure = null;
        self.dirty = true;
        self.flush() catch {};
    }
    fn applyRemainingChanged(self: *View, _: bool) void {
        self.renamed("");
    }
    fn submitted(self: *View, _: []const u8) void {
        self.submit();
    }
    fn choice(self: *const View) ?domain.Choice {
        const selected = self.selected.peek() orelse return null;
        for (values, 0..) |value, index| if (std.mem.eql(u8, selected, value)) return @fromBackingInt(@intCast(index));
        return null;
    }
    fn submit(self: *View) void {
        if (!self.visible or self.pending or self.primary_disabled.peek() or self.input.state.imeIsComposing()) return;
        const source = self.source orelse return;
        const request: Conflict.Request = switch (source.value.pending) {
            .context_required => return,
            .choice => |prompt| blk: {
                const selected = self.choice() orelse return;
                if (selected == .save_as) Name.validate(self.rename.peek()) catch {
                    self.failure = error.InvalidName;
                    self.dirty = true;
                    self.flush() catch {};
                    return;
                };
                break :blk .{ .select = .{ .key = prompt.key, .selection = .{ .choice = selected, .rename = self.rename.peek(), .apply_to_remaining = self.apply_remaining.peek() } } };
            },
            .overwrite_confirmation => |confirmation| .{ .confirm_overwrite = .{ .key = confirmation.targets[0].key, .ticket = confirmation.ticket } },
        };
        self.send(request);
    }
    fn send(self: *View, request: Conflict.Request) void {
        self.callbacks.decision(self.callbacks.context, request) catch |err| {
            _ = self.setError(request.key(), err);
            self.flush() catch {};
            return;
        };
        self.pending = true;
        self.failure = null;
        self.dirty = true;
        self.flush() catch {};
    }
    fn returnToChoice(self: *View) void {
        if (!self.visible or self.pending) return;
        const source = self.source orelse return;
        const confirmation = switch (source.value.pending) {
            .overwrite_confirmation => |value| value,
            else => return,
        };
        self.send(.{ .return_to_choice = .{ .key = confirmation.targets[0].key, .ticket = confirmation.ticket } });
    }
    fn postpone(self: *View) void {
        if (!self.visible) return;
        const source = self.source orelse return;
        const prompt = switch (source.value.pending) {
            .choice => |value| value,
            else => return,
        };
        self.callbacks.defer_conflict(self.callbacks.context, prompt.key) catch |err| {
            _ = self.setError(prompt.key, err);
            self.flush() catch {};
            return;
        };
        self.hide();
    }
    fn dismiss(self: *View) void {
        if (self.input.state.imeIsComposing()) {
            self.input.state.cancelImeComposition();
            return;
        }
        const source = self.source orelse return;
        switch (source.value.pending) {
            .choice => self.postpone(),
            .overwrite_confirmation => self.returnToChoice(),
            .context_required => self.hide(),
        }
    }
    fn onKey(key: ui.events.KeyCode, _: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (!self.visible or key != .escape) return .ignored;
        self.dismiss();
        return .handled;
    }
    fn refresh(self: *View) !void {
        const source = self.source.?.value;
        self.painted = S.theme.current();
        self.dialog.setBackground(S.theme.current().overlay);
        self.fade.setStyleInline(self.cx.allocator, S.fade());
        self.grip.setStyleInline(self.cx.allocator, S.grip());
        tuneText(self.title, S.title());
        tuneText(self.caption, S.caption());
        tuneText(self.target, S.path());
        tuneText(self.metadata, S.detail());
        tuneText(self.hint, S.detail());
        tuneText(self.confirmation_paths, S.path());
        const confirmation = source.pending == .overwrite_confirmation;
        const invalid_context = source.pending == .context_required;
        self.mode = if (confirmation) (if (source.pending.overwrite_confirmation.direction == .upload) .remote_confirmation else .local_confirmation) else if (self.choice() == .save_as) .rename else .choice;
        // The remote confirmation is the older compact 460px card; its
        // prototype has a top reflection, without the floating-card grip.
        self.fade.setDisplay(if (self.mode == .remote_confirmation) .none else .flex);
        self.grip.setDisplay(if (self.mode == .remote_confirmation) .none else .flex);
        self.header.setStyleInline(self.cx.allocator, S.header(self.mode));
        self.scroll.container.setStyleInline(self.cx.allocator, S.viewport(self.mode));
        self.footer.setStyleInline(self.cx.allocator, S.footer(self.mode));
        self.choices.setDisplay(if (confirmation) .none else .flex);
        self.confirmation.setDisplay(if (confirmation) .flex else .none);
        self.pause.setDisplay(if (confirmation or invalid_context) .none else .flex);
        self.back.setDisplay(if (confirmation) .flex else .none);
        self.radios.setDisplay(if (invalid_context) .none else .flex);
        self.checkbox.setDisplay(if (invalid_context) .none else .flex);
        self.input.node.setDisplay(if (!confirmation and !invalid_context and self.choice() == .save_as) .flex else .none);
        self.hint.setDisplay(if (confirmation or self.choice() == .save_as) .none else .flex);
        const prompt_locked = source.pending == .choice and source.pending.choice.phase != .waiting;
        self.disabled.set(self.pending or invalid_context or prompt_locked);
        var invalid_name = false;
        if (self.choice() == .save_as) Name.validate(self.rename.peek()) catch {
            invalid_name = true;
        };
        self.primary_disabled.set(self.pending or invalid_context or prompt_locked or (!confirmation and (self.choice() == null or invalid_name)));
        self.input.input_container.setStyleInline(self.cx.allocator, S.input());
        self.input.state.tokens = self.cx.tokens;
        self.input.state.font_size = 11.5;
        self.input.state.line_height = 17;
        self.input.state.char_width = 6.9;
        self.input.state.dirty = true;
        for (self.rows, 0..) |row, index| {
            const selected = self.choice() == @as(domain.Choice, @fromBackingInt(@intCast(index)));
            row.setStyleInline(self.cx.allocator, S.choice(selected));
            const asset = if (selected) ui.icons.circle_check else ui.icons.circle;
            setIcon(self.glyphs[index], asset, 16, if (index == 3) S.theme.current().danger else if (selected) S.theme.current().accent else S.theme.current().fg_2);
            tuneText(self.labels[index], S.choiceText(index == 3));
        }
        var buffer: [8192]u8 = undefined;
        if (confirmation) {
            try self.paintConfirmation(source.pending.overwrite_confirmation);
        } else if (invalid_context) {
            const entry = source.pending.context_required;
            try self.title.setTextContent(self.cx.allocator, "同名文件处理");
            try self.caption.setTextContent(self.cx.allocator, "原连接身份不可用");
            try self.target.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "目标 {s}", .{entry.target_path}));
            try self.metadata.setTextContent(self.cx.allocator, "任务仍在等待处理，当前不能批准文件写入。");
            try self.hint.setTextContent(self.cx.allocator, "请从原传输任务重新打开处理。");
            self.primary_label.set("应用选择");
        } else {
            const prompt = source.pending.choice;
            try self.title.setTextContent(self.cx.allocator, "同名文件处理");
            try self.caption.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{s}冲突 · {s} · 会话#{d}", .{ if (prompt.direction == .upload) @as([]const u8, "上传") else "下载", std.fs.path.basename(prompt.target_path), @backingInt(prompt.key.original_owner.session_id) }));
            try self.target.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "目标 {s}", .{prompt.target_path}));
            const metadata = try metadataPair(self.cx.allocator, prompt.direction, prompt.source_metadata, if (prompt.target == .present) prompt.target.present.metadata else null);
            defer self.cx.allocator.free(metadata);
            try self.metadata.setTextContent(self.cx.allocator, metadata);
            if (self.choice() == .keep_both and prompt.suggested_path != null) {
                try self.hint.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "将保留为 {s}", .{prompt.suggested_path.?}));
            } else try self.hint.setTextContent(self.cx.allocator, if (self.pending) "正在核对原目标…" else "覆盖须再次确认；未选择时不写入。");
            self.primary_label.set("应用选择");
        }
        const remote = self.mode == .remote_confirmation;
        self.primary_style.set(S.button(if (remote) 172 else 156, if (remote) 34 else 30, true, confirmation));
        self.primary_variant.set(if (confirmation) .danger else .primary);
        if (self.primary_disabled.peek()) {
            self.primary.setStyleInline(self.cx.allocator, S.disabledPrimary(confirmation));
        } else self.primary.unsetStyleInline(.{ .background = ui.Color.TRANSPARENT, .opacity = 1 });
        self.back_style.set(S.button(if (remote) 112 else 116, if (remote) 34 else 30, false, false));
        setIcon(self.header_icon, if (confirmation) ui.icons.triangle_alert else ui.icons.files, 18, S.theme.current().accent);
        self.close.behavior.interaction.a11y.?.label = if (confirmation) "返回选择" else if (invalid_context) "关闭提示" else "暂不处理，暂停原任务";
        const issue = self.issueText();
        self.error_text.setDisplay(if (issue.len != 0) .flex else .none);
        try self.error_text.setTextContent(self.cx.allocator, issue);
        self.error_text.setTextColor(S.theme.current().danger_ink);
        self.cx.requestRedraw();
    }
    fn paintConfirmation(self: *View, confirmation: domain.Confirmation) !void {
        const remote = confirmation.direction == .upload;
        const first = confirmation.targets[0];
        var buffer: [8192]u8 = undefined;
        try self.title.setTextContent(self.cx.allocator, if (remote) "确认覆盖远程文件" else "确认覆盖本地文件");
        self.primary_label.set(if (remote) "覆盖远程文件" else "覆盖本地文件");
        self.confirmation.setStyleInline(self.cx.allocator, S.stack(if (remote) 10 else 12));
        self.notice.setStyleInline(self.cx.allocator, if (remote) S.notice() else S.localNotice());
        self.confirmation_detail.setDisplay(if (remote) .flex else .none);
        self.confirmation_warning.setDisplay(if (remote) .none else .flex);
        try self.confirmation_heading.setTextContent(self.cx.allocator, if (remote) "覆盖远程文件？" else try std.fmt.bufPrint(&buffer, "覆盖本地 {s}？", .{std.fs.path.basename(first.path)}));
        tuneText(self.confirmation_heading, if (remote) S.caption() else S.text(14, 700, false, 22));
        self.confirmation_heading.setTextColor(S.theme.current().danger_ink);
        try self.confirmation_detail.setTextContent(self.cx.allocator, "所列目标的现有文件将被替换。此操作无法撤销。");
        self.confirmation_detail.setTextColor(S.theme.current().fg_2);
        var paths = std.Io.Writer.Allocating.init(self.cx.allocator);
        defer paths.deinit();
        if (remote) try paths.writer.print("上传 · 会话#{d}\n远程目标\n", .{@backingInt(confirmation.original_owner.session_id)});
        if (confirmation.targets.len > 1) try paths.writer.print("本次覆盖 {d} 个文件\n", .{confirmation.targets.len});
        for (confirmation.targets, 0..) |target, index| {
            if (index != 0) try paths.writer.writeAll("\n");
            try paths.writer.writeAll(target.path);
            if (confirmation.targets.len > 1) {
                const value = try metadataText(self.cx.allocator, target.version.metadata);
                defer self.cx.allocator.free(value);
                try paths.writer.print("\n现有 {s}", .{value});
            }
        }
        try self.confirmation_paths.setTextContent(self.cx.allocator, paths.writer.buffered());
        self.confirmation_paths.setStyleInline(self.cx.allocator, S.label(if (remote) 60 else 18));
        const from = try sizeText(self.cx.allocator, if (self.source_metadata) |value| value.size else null);
        defer self.cx.allocator.free(from);
        const to = try sizeText(self.cx.allocator, first.version.metadata.size);
        defer self.cx.allocator.free(to);
        const size = try std.fmt.allocPrint(self.cx.allocator, "{s} {s} → {s}现有 {s}", .{ if (remote) @as([]const u8, "本地") else "远程源", from, if (remote) @as([]const u8, "远程") else "本地", to });
        defer self.cx.allocator.free(size);
        try self.confirmation_metadata.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{s} · 会话#{d}", .{ size, @backingInt(confirmation.original_owner.session_id) }));
        tuneText(self.confirmation_metadata, S.text(11.5, 400, false, 18));
        try self.confirmation_warning.setTextContent(self.cx.allocator, "替换本地文件，操作不可撤销；返回保留冲突等待，不删除远程源。");
        self.confirmation_warning.setTextColor(S.theme.current().warn_ink);
    }
    fn issueText(self: *const View) []const u8 {
        if (self.failure) |failure| return switch (failure) {
            error.InvalidName => "名称不能为空，不能为 . 或 ..，不能包含路径分隔符或 NUL。",
            error.StaleConflict, error.StaleConfirmation, error.StaleAttempt, error.UnknownJob, error.InvalidState => "原任务或目标已变化，请重新核对当前冲突。",
            error.AccessDenied, error.PermissionDenied => "没有目标文件的写入权限，原选择与名称已保留。",
            else => "操作未被接受，原选择与名称已保留，可重新处理。",
        };
        const source = self.source orelse return "";
        if (source.value.issue) |issue| return switch (issue) {
            .invalid_name => "文件名无效，输入已保留，请修改。",
            .invalid_decision => "原任务或目标已变化，请重新核对。",
            .permission_denied => "没有目标文件的写入权限。",
            .io => "无法核对目标文件，原选择与名称已保留。",
            .unsupported => "当前连接暂不支持此操作。",
        };
        if (source.value.pending == .choice) if (source.value.pending.choice.issue) |issue| return switch (issue) {
            .target_changed => "目标文件已变化，请重新选择处理方式。",
            .name_exists => "该名称已存在，请修改另存文件名。",
            .invalid_name => "文件名无效，输入已保留，请修改。",
            .io_failed => "无法核对目标文件，原选择与名称已保留。",
        };
        return "";
    }
};

fn keyOf(snapshot: Conflict.Snapshot) ?domain.Key {
    return switch (snapshot.pending) {
        .choice => |value| value.key,
        .overwrite_confirmation => |value| if (value.targets.len != 0) value.targets[0].key else null,
        .context_required => null,
    };
}
fn sameCapture(a: Conflict.Snapshot, b: Conflict.Snapshot) bool {
    if (a.engine_job != b.engine_job or !std.meta.eql(a.context, b.context)) return false;
    const ak = keyOf(a);
    const bk = keyOf(b);
    if (ak != null or bk != null) return ak != null and bk != null and std.meta.eql(ak.?, bk.?);
    return a.pending.context_required.entry == b.pending.context_required.entry and a.pending.context_required.revision == b.pending.context_required.revision;
}
fn rejectOld(old: Conflict.Snapshot, next: Conflict.Snapshot) !void {
    const ak = keyOf(old) orelse return;
    const bk = keyOf(next) orelse return;
    if (ak.intent_id == bk.intent_id and ak.job == bk.job and std.meta.eql(ak.owner, bk.owner) and ak.original_owner.eql(bk.original_owner)) {
        if (bk.attempt < ak.attempt or (bk.attempt == ak.attempt and (bk.entry < ak.entry or (bk.entry == ak.entry and bk.revision < ak.revision)))) return error.StaleConflict;
    }
    if (std.meta.eql(ak, bk) and old.pending == .choice and next.pending == .choice) {
        const before = old.pending.choice;
        const after = next.pending.choice;
        if (!std.mem.eql(u8, before.source_path, after.source_path) or !std.mem.eql(u8, before.target_path, after.target_path) or !before.source_endpoint.eql(after.source_endpoint) or !before.target_endpoint.eql(after.target_endpoint) or !std.meta.eql(before.target, after.target)) return error.FrozenConflictChanged;
    }
    if (old.pending == .overwrite_confirmation and next.pending == .overwrite_confirmation and std.meta.eql(old.pending.overwrite_confirmation.ticket, next.pending.overwrite_confirmation.ticket) and !confirmationEqual(old.pending.overwrite_confirmation, next.pending.overwrite_confirmation)) return error.FrozenConflictChanged;
}
fn snapshotEqual(a_: Conflict.Snapshot, b: Conflict.Snapshot) bool {
    if (a_.engine_job != b.engine_job or !std.meta.eql(a_.context, b.context) or a_.issue != b.issue or std.meta.activeTag(a_.pending) != std.meta.activeTag(b.pending)) return false;
    return switch (a_.pending) {
        .choice => |left| blk: {
            const right = b.pending.choice;
            break :blk std.meta.eql(left.key, right.key) and left.direction == right.direction and left.source_endpoint.eql(right.source_endpoint) and left.target_endpoint.eql(right.target_endpoint) and std.mem.eql(u8, left.source_path, right.source_path) and std.mem.eql(u8, left.target_path, right.target_path) and std.meta.eql(left.source_metadata, right.source_metadata) and std.meta.eql(left.target, right.target) and left.selection.choice == right.selection.choice and left.selection.apply_to_remaining == right.selection.apply_to_remaining and std.mem.eql(u8, left.selection.rename, right.selection.rename) and optionalTextEqual(left.suggested_path, right.suggested_path) and left.phase == right.phase and left.issue == right.issue;
        },
        .context_required => |left| blk: {
            const right = b.pending.context_required;
            break :blk left.entry == right.entry and left.revision == right.revision and std.mem.eql(u8, left.source_path, right.source_path) and std.mem.eql(u8, left.target_path, right.target_path) and std.meta.eql(left.source_metadata, right.source_metadata) and std.meta.eql(left.target, right.target);
        },
        .overwrite_confirmation => |left| confirmationEqual(left, b.pending.overwrite_confirmation),
    };
}
fn confirmationEqual(a_: domain.Confirmation, b: domain.Confirmation) bool {
    if (!std.meta.eql(a_.ticket, b.ticket) or !a_.original_owner.eql(b.original_owner) or a_.direction != b.direction or !a_.endpoint.eql(b.endpoint) or a_.targets.len != b.targets.len) return false;
    for (a_.targets, b.targets) |left, right| if (!std.meta.eql(left.key, right.key) or !std.mem.eql(u8, left.path, right.path) or !std.meta.eql(left.version, right.version)) return false;
    return true;
}
fn optionalTextEqual(a_: ?[]const u8, b: ?[]const u8) bool {
    return if (a_) |left| if (b) |right| std.mem.eql(u8, left, right) else false else b == null;
}
fn validate(value: Conflict.Snapshot) !void {
    if (value.engine_job == 0) return error.InvalidConflictIdentity;
    const key = keyOf(value) orelse {
        if (value.pending != .context_required or value.pending.context_required.revision == 0) return error.InvalidConflictIdentity;
        return;
    };
    if (key.intent_id == 0 or key.job == 0 or key.attempt == 0 or key.revision == 0 or @backingInt(key.original_owner.session_id) == 0 or key.original_owner.generation == 0) return error.InvalidConflictIdentity;
    const context = value.context orelse return error.ConflictContextRequired;
    if (context.intent_id != key.intent_id or context.job != key.job or context.attempt != key.attempt or !context.original_owner.eql(key.original_owner) or !std.meta.eql(context.resource_owner, key.owner)) return error.ConflictOwnerMismatch;
    if (value.pending == .choice) {
        const prompt = value.pending.choice;
        if (!prompt.source_endpoint.eql(context.source_endpoint) or !prompt.target_endpoint.eql(context.target_endpoint)) return error.ConflictOwnerMismatch;
    }
    if (value.pending == .overwrite_confirmation) {
        const confirmation = value.pending.overwrite_confirmation;
        if (confirmation.ticket.id == 0 or confirmation.ticket.intent_id != key.intent_id or !std.meta.eql(confirmation.ticket.owner, key.owner) or !confirmation.original_owner.eql(key.original_owner) or !confirmation.endpoint.eql(context.target_endpoint)) return error.ConflictOwnerMismatch;
        for (confirmation.targets) |target| if (target.key.intent_id != key.intent_id or target.key.job != key.job or target.key.attempt != key.attempt or !std.meta.eql(target.key.owner, key.owner) or !target.key.original_owner.eql(key.original_owner)) return error.ConflictOwnerMismatch;
    }
}
fn addText(cx: *ui.Cx, parent: *ui.Node, id: []const u8, style: ui.TextStyle, min: f32) !*ui.Node {
    const node = try ui.text(cx, "", style);
    node.setStyleInline(cx.allocator, S.label(min));
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}
fn setIcon(node: *ui.Node, asset: ui.SvgAsset, size: f32, color: ui.Color) void {
    if (asset.icon_id) |id| if (asset.pickRep(size)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = color });
}
fn tuneText(node: *ui.Node, style: ui.TextStyle) void {
    if (node.getText()) |old| {
        var text = old;
        text.font_size = style.font_size;
        text.font_weight = style.font_weight;
        text.line_height = style.line_height;
        text.color = style.color;
        node.setText(text);
    }
}
fn metadataText(allocator: std.mem.Allocator, metadata: ?domain.Metadata) ![]u8 {
    const size = if (metadata) |m| m.size else null;
    const modified = if (metadata) |m| m.modified_at else null;
    var buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    if (size) |n| {
        if (n >= 1024 * 1024 and n % (1024 * 1024) == 0) try buffer.writer.print("{d} MiB", .{n / (1024 * 1024)}) else try buffer.writer.print("{d} B", .{n});
    } else try buffer.writer.writeAll("大小未知");
    if (modified) |seconds| {
        if (seconds <= 253402300799) {
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
            const yd = epoch.getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            const day = epoch.getDaySeconds();
            try buffer.writer.print(" · {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ yd.year, @backingInt(md.month), md.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
        } else try buffer.writer.print(" · {d} s (UTC)", .{seconds});
    } else try buffer.writer.writeAll(" · 修改时间未知");
    return buffer.toOwnedSlice();
}
fn sizeText(allocator: std.mem.Allocator, value: ?u64) ![]u8 {
    const n = value orelse return allocator.dupe(u8, "大小未知");
    return if (n >= 1024 * 1024 and n % (1024 * 1024) == 0) std.fmt.allocPrint(allocator, "{d} MiB", .{n / (1024 * 1024)}) else std.fmt.allocPrint(allocator, "{d} B", .{n});
}
fn metadataPair(allocator: std.mem.Allocator, direction: transfer.Direction, source: ?domain.Metadata, target: ?domain.Metadata) ![]u8 {
    const from = try metadataText(allocator, source);
    defer allocator.free(from);
    const to = try metadataText(allocator, target);
    defer allocator.free(to);
    return std.fmt.allocPrint(allocator, "来源 {s}{s} → 现有目标 {s}{s}", .{ if (direction == .upload) @as([]const u8, "本地 ") else "远程 ", from, if (direction == .upload) @as([]const u8, "远程 ") else "本地 ", to });
}
