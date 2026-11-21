//! Shared Step 3 review summary presentation across SSH, SFTP, BMC and Web.
const std = @import("std");
const ui = @import("ui");
const S = @import("wizard_styles.zig");

pub const FieldSpec = struct {
    label: []const u8,
    test_id: []const u8,
    mono: bool = false,
};

pub const Config = struct {
    icon: ui.SvgAsset = ui.icons.terminal,
    endpoint_caption: []const u8 = "目标地址",
    details_title: []const u8 = "认证与验证",
    edit_identity_id: []const u8 = "wizard.review.modify",
    edit_route_id: []const u8 = "wizard.review.route.modify",
    fields: [3]FieldSpec,
    note: []const u8,
    locked: *ui.Signal(bool),
    on_edit_identity: ui.Handler(void),
    on_edit_route: ui.Handler(void),
};

pub const RouteNodeData = struct {
    name: []const u8,
    caption: []const u8,
    icon: ui.SvgAsset,
    highlighted: bool = false,
};

pub const Data = struct {
    icon: ui.SvgAsset,
    name: []const u8,
    subtitle: []const u8,
    protocol_badge: []const u8 = "",
    endpoint_caption: []const u8 = "目标地址",
    endpoint: []const u8,
    values: [3][]const u8,
    options: []const u8 = "",
    route_nodes: []const RouteNodeData,
    note: ?[]const u8 = null,
    show_note: bool = true,
};

pub const Summary = struct {
    cx: *ui.Cx,
    config: Config,
    summary_card: *ui.Node = undefined,
    icon_tile: *ui.Node = undefined,
    icon: *ui.Node = undefined,
    name: *ui.Node = undefined,
    subtitle: *ui.Node = undefined,
    protocol_badge: *ui.Node = undefined,
    endpoint_caption: *ui.Node = undefined,
    endpoint: *ui.Node = undefined,
    details_card: *ui.Node = undefined,
    details_title: *ui.Node = undefined,
    edit_identity_button: *ui.Node = undefined,
    edit_identity_icon: *ui.Node = undefined,
    edit_identity_label: *ui.Node = undefined,
    edit_identity_style: *ui.Signal(ui.BoxStyle) = undefined,
    field_labels: [3]*ui.Node = undefined,
    field_values: [3]*ui.Node = undefined,
    options: *ui.Node = undefined,
    route_card: *ui.Node = undefined,
    route_title: *ui.Node = undefined,
    edit_route_button: *ui.Node = undefined,
    edit_route_icon: *ui.Node = undefined,
    edit_route_label: *ui.Node = undefined,
    edit_route_style: *ui.Signal(ui.BoxStyle) = undefined,
    route_scroll: ui.widgets.ScrollAreaResult = undefined,
    route_nodes: [10]*ui.Node = undefined,
    route_tiles: [10]*ui.Node = undefined,
    route_icons: [10]*ui.Node = undefined,
    route_names: [10]*ui.Node = undefined,
    route_captions: [10]*ui.Node = undefined,
    route_icon_assets: [10]ui.SvgAsset = @splat(ui.icons.route),
    route_highlighted: [10]bool = @splat(false),
    route_count: usize = 0,
    note_row: *ui.Node = undefined,
    note_icon: *ui.Node = undefined,
    note_label: *ui.Node = undefined,
    current_icon: ui.SvgAsset = ui.icons.terminal,
    node_ids: [10][32]u8 = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, config: Config) !*Summary {
        const self = try scope.createState(Summary, .{
            .cx = cx,
            .config = config,
            .current_icon = config.icon,
        });
        const a = cx.allocator;
        const colors = S.theme.current();

        const summary = try ui.box(cx, S.reviewIdentity(), .{});
        self.summary_card = summary;
        summary.meta.ownership.meta.test_id = "wizard.review.summary";
        const icon_tile = try ui.box(cx, S.reviewIconTile(44, true), .{});
        self.icon_tile = icon_tile;
        self.icon = try ui.iconTint(cx, config.icon, colors.accent_ink, S.icon(24));
        self.icon.meta.ownership.meta.test_id = "wizard.review.summary.icon";
        try icon_tile.appendChild(a, self.icon);
        try summary.appendChild(a, icon_tile);

        const identity_copy = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 2 }, .{});
        self.name = try ui.text(cx, "", S.summaryName());
        self.name.meta.ownership.meta.test_id = "wizard.review.name";
        self.name.setStyleInline(a, .{ .width = .fill() });
        try identity_copy.appendChild(a, self.name);
        self.subtitle = try ui.text(cx, "", S.text(12, 400, false));
        self.subtitle.setStyleInline(a, .{ .width = .fill() });
        try identity_copy.appendChild(a, self.subtitle);
        try summary.appendChild(a, identity_copy);

        const endpoint = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .flex = 0.7, .direction = .column, .align_items = .end, .gap = 2 }, .{});
        var caption_style = S.row(18);
        caption_style.justify = .end;
        const caption_row = try ui.box(cx, caption_style, .{});
        self.protocol_badge = try ui.text(cx, "", S.text(12, 400, false));
        self.protocol_badge.meta.ownership.meta.test_id = "wizard.review.protocol";
        try caption_row.appendChild(a, self.protocol_badge);
        self.endpoint_caption = try ui.text(cx, config.endpoint_caption, S.text(12, 400, false));
        try caption_row.appendChild(a, self.endpoint_caption);
        try endpoint.appendChild(a, caption_row);
        var endpoint_text = S.text(18, 600, true);
        endpoint_text.text_align = .end;
        self.endpoint = try ui.text(cx, "", endpoint_text);
        self.endpoint.meta.ownership.meta.test_id = "wizard.review.endpoint";
        self.endpoint.setStyleInline(a, .{ .width = .fill() });
        try endpoint.appendChild(a, self.endpoint);
        try summary.appendChild(a, endpoint);
        try parent.appendChild(a, summary);

        const columns = try ui.box(cx, S.reviewColumns(), .{});
        const details = try ui.box(cx, S.reviewRoute(), .{});
        details.meta.ownership.meta.test_id = "wizard.review.authentication";
        self.details_card = details;
        const auth_header = try ui.box(cx, S.row(26), .{});
        self.details_title = try ui.text(cx, config.details_title, S.text(14, 600, false));
        try auth_header.appendChild(a, self.details_title);
        try auth_header.appendChild(a, try ui.spacer(cx));
        self.edit_identity_style = try scope.createSignal(ui.BoxStyle, editButtonStyle(98, config.locked.peek()));
        const edit_identity = try mountEditButton(cx, scope, auth_header, "编辑连接信息", config.edit_identity_id, 98, config.locked, self.edit_identity_style, config.on_edit_identity);
        self.edit_identity_button = edit_identity.button;
        self.edit_identity_icon = edit_identity.icon;
        self.edit_identity_label = edit_identity.label;
        try details.appendChild(a, auth_header);

        const fields = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .column, .padding = .{ .bottom = 16 } }, .{});
        for (config.fields, 0..) |spec, i| {
            var row_style = S.row(32);
            row_style.height = .fill();
            row_style.min_height = 18;
            row_style.flex = 1;
            const row = try ui.box(cx, row_style, .{});
            const key = try ui.text(cx, spec.label, S.text(12, 400, false));
            key.setStyleInline(a, .{ .width = .{ .px = 82 }, .flex_shrink = 0 });
            self.field_labels[i] = key;
            try row.appendChild(a, key);
            const value = try ui.text(cx, "", S.text(13, 550, spec.mono));
            value.meta.ownership.meta.test_id = spec.test_id;
            value.setStyleInline(a, .{ .width = .fill(), .min_width = 0, .flex = 1 });
            self.field_values[i] = value;
            try row.appendChild(a, value);
            try fields.appendChild(a, row);
        }
        self.options = try ui.textStyled(cx, S.summaryOptions, "");
        self.options.meta.ownership.meta.test_id = "wizard.review.options";
        try fields.appendChild(a, self.options);
        try details.appendChild(a, fields);
        try columns.appendChild(a, details);

        const route_card = try ui.box(cx, S.reviewRoute(), .{});
        self.route_card = route_card;
        const route_header = try ui.box(cx, S.row(26), .{});
        self.route_title = try ui.text(cx, "连接路径", S.text(14, 600, false));
        try route_header.appendChild(a, self.route_title);
        try route_header.appendChild(a, try ui.spacer(cx));
        self.edit_route_style = try scope.createSignal(ui.BoxStyle, editButtonStyle(70, config.locked.peek()));
        const edit_route = try mountEditButton(cx, scope, route_header, "编辑路径", config.edit_route_id, 70, config.locked, self.edit_route_style, config.on_edit_route);
        self.edit_route_button = edit_route.button;
        self.edit_route_icon = edit_route.icon;
        self.edit_route_label = edit_route.label;
        try route_card.appendChild(a, route_header);

        const row_height = S.reviewRouteRowHeight(false);
        const route = try ui.widgets.ScrollArea(.{ .height = 3 * row_height, .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.route_scroll = route;
        route.state.scrollbar_fade.fade_delay = std.math.maxInt(u32);
        route.container.meta.ownership.meta.test_id = "wizard.review.route.viewport";
        route.container.setStyleInline(a, .{ .width = .fill(), .flex_shrink = 0 });
        route.content.meta.ownership.meta.test_id = "wizard.review.route";
        route.content.setStyleInline(a, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = .{ .right = 12 } });
        for (0..10) |i| {
            var style = S.row(row_height);
            style.gap = 11;
            const item = try ui.box(cx, style, .{});
            item.meta.ownership.meta.test_id = try std.fmt.bufPrint(&self.node_ids[i], "wizard.review.route.node.{d}", .{i});
            self.route_nodes[i] = item;
            const tile = try ui.box(cx, S.reviewIconTile(26, false), .{});
            self.route_tiles[i] = tile;
            const node_icon = try ui.iconTint(cx, ui.icons.route, colors.fg_2, S.icon(16));
            self.route_icons[i] = node_icon;
            try tile.appendChild(a, node_icon);
            try item.appendChild(a, tile);
            const node_name = try ui.text(cx, "", S.text(13, 550, false));
            node_name.setStyleInline(a, .{ .width = .fill(), .min_width = 0, .flex = 1 });
            self.route_names[i] = node_name;
            try item.appendChild(a, node_name);
            const caption = try ui.text(cx, "", S.text(12, 400, false));
            caption.setStyleInline(a, .{ .flex_shrink = 0 });
            self.route_captions[i] = caption;
            try item.appendChild(a, caption);
            try route.content.appendChild(a, item);
            item.setDisplay(.none);
        }
        try route_card.appendChild(a, route.container);
        try columns.appendChild(a, route_card);
        try parent.appendChild(a, columns);

        var note_style = S.row(18);
        note_style.height = .{ .fit = .{} };
        note_style.align_items = .start;
        const note = try ui.box(cx, note_style, .{});
        self.note_row = note;
        self.note_icon = try ui.iconTint(cx, ui.icons.info, colors.fg_2, S.icon(14));
        try note.appendChild(a, self.note_icon);
        var note_text = S.text(12, 400, false);
        note_text.wrap = .word;
        note_text.text_overflow = .clip;
        self.note_label = try ui.text(cx, config.note, note_text);
        self.note_label.setStyleInline(a, .{ .width = .fill(), .min_width = 0, .flex = 1 });
        try note.appendChild(a, self.note_label);
        try parent.appendChild(a, note);

        try scope.createEffect(.{ .summary = self, .locked = config.locked, .publication = try cx.themeSignal(scope) }, struct {
            fn sync(ctx: anytype) void {
                _ = ctx.publication.get();
                _ = ctx.locked.get();
                ctx.summary.paint();
            }
        }.sync);
        return self;
    }

    pub fn update(self: *Summary, data: Data) void {
        const a = self.cx.allocator;
        self.current_icon = data.icon;
        self.name.setTextContent(a, data.name) catch {};
        self.subtitle.setTextContent(a, data.subtitle) catch {};
        self.protocol_badge.setTextContent(a, data.protocol_badge) catch {};
        self.protocol_badge.setDisplay(if (data.protocol_badge.len != 0) .flex else .none);
        self.endpoint_caption.setTextContent(a, data.endpoint_caption) catch {};
        self.endpoint.setTextContent(a, data.endpoint) catch {};
        for (data.values, self.field_values) |value, node| {
            node.setTextContent(a, value) catch {};
        }
        self.options.setTextContent(a, data.options) catch {};
        self.options.setDisplay(if (data.options.len != 0) .flex else .none);

        const count = @min(data.route_nodes.len, self.route_nodes.len);
        self.route_count = count;
        for (0..self.route_nodes.len) |i| {
            const node = self.route_nodes[i];
            if (i >= count) {
                node.setDisplay(.none);
                continue;
            }
            node.setDisplay(.flex);
            const entry = data.route_nodes[i];
            self.route_icon_assets[i] = entry.icon;
            self.route_highlighted[i] = entry.highlighted;
            self.route_names[i].setTextContent(a, entry.name) catch {};
            self.route_captions[i].setTextContent(a, entry.caption) catch {};
        }
        if (count > 3) self.route_scroll.state.scrollbar_fade.onActivity();
        if (data.note) |note_copy| self.note_label.setTextContent(a, note_copy) catch {};
        self.note_row.setDisplay(if (data.show_note) .flex else .none);
        self.paint();
    }

    pub fn setCompact(self: *Summary, compact: bool) void {
        const a = self.cx.allocator;
        self.summary_card.setStyleInline(a, .{ .height = .{ .px = if (compact) 58 else 78 } });
        for ([_]*ui.Node{ self.details_card, self.route_card }) |card| {
            card.setStyleInline(a, .{ .height = .{ .px = if (compact) 134 else 178 }, .padding = .{ .left = 16, .right = 16, .top = if (compact) 4 else 12 } });
        }
        const row_height = S.reviewRouteRowHeight(compact);
        self.route_scroll.container.setStyleInline(a, .{ .height = .{ .px = 3 * row_height } });
        for (self.route_nodes) |node| node.setStyleInline(a, .{ .height = .{ .px = row_height } });
    }

    pub fn resetScroll(self: *Summary) void {
        ui.widgets.setScrollY(self.route_scroll.state, self.route_scroll.content, 0);
    }

    pub fn paint(self: *Summary) void {
        const a = self.cx.allocator;
        const colors = S.theme.current();
        const is_locked = self.config.locked.peek();

        self.summary_card.setBackground(S.reviewIdentity().background.?);
        self.icon_tile.setBackground(S.reviewIconTile(44, true).background.?);
        paintIcon(self.icon, self.current_icon, 24, colors.accent_ink);
        self.name.setTextColor(colors.fg_1);
        self.subtitle.setTextColor(colors.fg_2);
        self.protocol_badge.setTextColor(colors.fg_2);
        self.endpoint_caption.setTextColor(colors.fg_2);
        self.endpoint.setTextColor(colors.fg_1);

        const card_bg = S.reviewRoute().background.?;
        self.details_card.setBackground(card_bg);
        self.route_card.setBackground(card_bg);
        self.details_title.setTextColor(colors.fg_1);
        self.route_title.setTextColor(colors.fg_1);

        const id_style = editButtonStyle(98, is_locked);
        self.edit_identity_style.set(id_style);
        self.edit_identity_button.setStyleInline(a, id_style);
        paintIcon(self.edit_identity_icon, ui.icons.pencil, 16, colors.accent);
        self.edit_identity_label.setTextColor(colors.accent);

        const route_style = editButtonStyle(70, is_locked);
        self.edit_route_style.set(route_style);
        self.edit_route_button.setStyleInline(a, route_style);
        paintIcon(self.edit_route_icon, ui.icons.pencil, 16, colors.accent);
        self.edit_route_label.setTextColor(colors.accent);

        for (self.field_labels) |label| label.setTextColor(colors.fg_2);
        for (self.field_values) |value| value.setTextColor(colors.fg_1);
        self.options.setTextColor(colors.fg_2);

        for (0..self.route_count) |i| {
            const highlighted = self.route_highlighted[i];
            self.route_names[i].setTextColor(if (highlighted) colors.accent_ink else colors.fg_1);
            self.route_captions[i].setTextColor(colors.fg_2);
            paintIcon(self.route_icons[i], self.route_icon_assets[i], 16, if (highlighted) colors.accent_ink else colors.fg_2);
            self.route_tiles[i].setBackground(S.reviewIconTile(26, highlighted).background.?);
        }

        paintIcon(self.note_icon, ui.icons.info, 14, colors.fg_2);
        self.note_label.setTextColor(colors.fg_2);
    }
};

fn editButtonStyle(width: f32, disabled: bool) ui.BoxStyle {
    var style = S.button(width, 26, false);
    style.background = ui.Color.TRANSPARENT;
    style.opacity = if (disabled) 0.4 else 1;
    return style;
}

fn mountEditButton(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, label_text: []const u8, id: []const u8, width: f32, locked: *ui.Signal(bool), style: *ui.Signal(ui.BoxStyle), on_click: ui.Handler(void)) !struct { button: *ui.Node, icon: *ui.Node, label: *ui.Node } {
    const a = cx.allocator;
    const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label_text, .disabled = locked, .base_style = style, .on_click = on_click }).mount(scope, cx);
    for (button.children.items) |child| child.setDisplay(.none);
    button.setStyleInline(a, editButtonStyle(width, locked.peek()));
    button.meta.ownership.meta.test_id = id;
    const icon = try ui.iconTint(cx, ui.icons.pencil, S.theme.current().accent, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    try button.appendChild(a, icon);
    var text_style = S.action(false);
    text_style.color = S.theme.current().accent;
    const label = try ui.text(cx, label_text, text_style);
    try button.appendChild(a, label);
    try parent.appendChild(a, button);
    return .{ .button = button, .icon = icon, .label = label };
}

fn paintIcon(node: *ui.Node, asset: ui.SvgAsset, size: f32, tint: ui.Color) void {
    if (asset.icon_id) |id| if (asset.pickRep(size)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = tint });
}
