//! Independent AI workspace shell: three-column page chrome and inspector.
//! Surfaces, radii and state colors reuse the application theme tokens.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const sidebar = @import("sidebar_styles.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

pub const left_width = sidebar.expanded_width;
pub const column_gap: f32 = 12;
pub const inspector_width: f32 = 340;
pub const inspector_min_width: f32 = 280;
pub const inspector_max_width: f32 = 640;
pub const center_min_width: f32 = 360;
pub const compact_width: f32 = 780;
pub const header_height: f32 = 44;
pub const rail_padding: f32 = 10;

pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .row, .gap = column_gap, .background = ui.Color.TRANSPARENT, .overflow = .hidden };
}

pub fn leftRail(t: *const ui.ThemeTokens) ui.BoxStyle {
    var panel = sidebar.panel(t);
    panel.width = .{ .px = left_width };
    panel.min_width = 0;
    panel.gap = 10;
    panel.padding = .{ .left = rail_padding, .right = rail_padding, .top = 8, .bottom = 10 };
    return panel;
}

pub fn centerPane(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .fill(),
        .min_width = 0,
        .min_height = 0,
        .flex = 1,
        .direction = .column,
        .background = ui.Color.TRANSPARENT,
        .overflow = .hidden,
        .overflow_hidden = true,
    };
}

pub fn inspector(t: *const ui.ThemeTokens) ui.BoxStyle {
    var panel = sidebar.panel(t);
    panel.width = .{ .px = inspector_width };
    panel.min_width = 0;
    return panel;
}

pub fn inspectorResize() ui.BoxStyle {
    // It occupies the existing gutter, not an additional column.
    return .{
        .width = .{ .px = column_gap },
        .height = .fill(),
        .flex_shrink = 0,
        .margin = .{ .left = -column_gap, .right = -column_gap },
        .align_items = .center,
        .justify = .center,
        .cursor = .ew_resize,
        .hit_behavior = .@"opaque",
    };
}

pub fn railHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    var header = sidebar.header();
    header.width = .fill();
    header.height = .{ .px = header_height - 16 };
    return header;
}

pub fn railTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return sidebar.text(13, 600, false);
}

pub fn iconButton() ButtonStyle {
    var button = sidebar.headerAction();
    button.text_color = theme.current().fg_2;
    return button;
}

pub fn searchField(_: *const ui.ThemeTokens) ui.BoxStyle {
    var search = sidebar.search();
    search.width = .fill();
    return search;
}

pub fn searchInput() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 28 }, .flex = 1, .min_width = 0, .padding = .{}, .border = .{ .width = 0 }, .background = ui.Color.TRANSPARENT };
}

pub fn listViewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .background = ui.Color.TRANSPARENT };
}

pub fn listContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 2, .padding = .{ .right = 1 } };
}

pub fn sessionRow(_: *const ui.ThemeTokens) ui.BoxStyle {
    var row = sidebar.host(false, false);
    row.height = .{ .fit = .{} };
    row.min_height = sidebar.host_height;
    row.padding = .{ .left = 9, .right = 9, .top = 5, .bottom = 5 };
    row.cursor = .pointer;
    return row;
}

pub fn sessionRowBackground(selected: bool, hovered: bool) ui.BoxStyle {
    return .{ .background = sidebar.host(selected, hovered).background, .corner_radius = 9 };
}
pub fn sessionTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return sidebar.text(12, 500, false);
}
pub fn sessionSubtitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return sidebar.text(10.5, 400, true);
}

pub fn railEmpty(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 1.6, .color = theme.current().fg_2, .wrap = .word };
}

pub fn centerHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .px = header_height },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 14, .right = 14, .top = 2, .bottom = 2 },
        .background = ui.Color.TRANSPARENT,
    };
}

pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 14, .font_weight = 650, .line_height = 20.0 / 14.0, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}

pub fn scopeBadge(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .max_width = 240,
        .height = .{ .px = 22 },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .padding = .{ .left = 7, .right = 7 },
        .background = theme.popupInset(),
        .border = .{ .width = 0, .radius = 11 },
    };
}

pub fn scopeBadgeText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 500, .line_height = 15.0 / 10.5, .color = theme.current().fg_2, .text_overflow = .ellipsis };
}

pub fn workspacePill(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .max_width = 170,
        .height = .{ .px = 28 },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 5,
        .padding = .{ .left = 9, .right = 8 },
        .background = theme.popupInset(),
        .border = .{ .width = 0, .radius = 14 },
        .overflow = .hidden,
        .overflow_hidden = true,
    };
}

pub fn workspaceText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 500, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .text_overflow = .ellipsis, .selectable = false };
}

pub fn inspectorToggle(open: bool) ButtonStyle {
    return .{
        .height = .{ .px = 28 },
        .padding = .{ .left = 9, .right = 9 },
        .gap = 5,
        .font_size = 11,
        .font_weight = 500,
        .text_color = if (open) theme.current().accent_ink else theme.current().fg_2,
        .background = if (open) theme.popupSelection() else theme.popupInset(),
        .corner_radius = 14,
        .border = .{ .width = 0, .radius = 14 },
        .flex_shrink = 0,
    };
}

pub fn centerSlot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .column, .background = ui.Color.TRANSPARENT };
}

pub fn composerSlot(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0, .direction = .column, .padding = .{ .left = 14, .right = 14, .top = 6, .bottom = 12 } };
}

pub fn inspectorHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = header_height }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 8 }, .flex_shrink = 0 };
}

pub fn inspectorTabs(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 2, .padding = ui.Padding.all(3), .margin = .{ .left = 8, .right = 8, .bottom = 6 }, .background = theme.current().well, .border = .{ .width = 0, .radius = 9 }, .flex_shrink = 0 };
}

pub fn tabButton(active: bool) ButtonStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 26 }, .gap = 0, .padding = .{}, .font_size = 11, .font_weight = if (active) 600 else 500, .text_color = if (active) theme.current().fg_1 else theme.current().fg_2, .background = if (active) sidebar.hostSelection() else ui.Color.TRANSPARENT, .corner_radius = 7, .border = .{ .width = 0, .radius = 7 } };
}
pub fn inspectorBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .column };
}

/// Hostable inspector page: matches the files page inset so reused child
/// views keep the same 8pt gutter inside the 340pt rail.
pub fn inspectorPage(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .column, .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 8 } };
}

/// Layout contract for nodes attached through set_inspector_host: fill the
/// page and let the real view keep its own direction, surfaces and colors.
pub fn inspectorHost(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0 };
}

pub fn page(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column };
}

pub fn emptyState(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column, .align_items = .center, .justify = .center, .gap = 6, .padding = .{ .left = 24, .right = 24 } };
}

pub fn emptyTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 600, .line_height = 17.0 / 12.0, .color = theme.current().fg_1, .text_align = .center };
}

pub fn emptyText(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 17.0 / 11.0, .color = theme.current().fg_2, .wrap = .word, .text_align = .center };
}

pub fn filesPage(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column, .gap = 8, .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 8 } };
}

pub fn fileTreeViewport(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .background = ui.Color.TRANSPARENT };
}

pub fn fileTreeContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .direction = .column, .gap = 1, .padding = .{ .right = 1 } };
}

pub fn fileRow(depth: u16) ui.BoxStyle {
    const indent: f32 = 5 + @as(f32, @floatFromInt(@min(depth, 12))) * 12;
    return .{
        .width = .fill(),
        .height = .{ .px = 26 },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .padding = .{ .left = indent, .right = 6 },
        .background = ui.Color.TRANSPARENT,
        .border = .{ .width = 0, .radius = 6 },
        .corner_radius = 6,
        .cursor = .pointer,
    };
}

pub fn fileRowBackground(selected: bool, hovered: bool) ui.BoxStyle {
    return .{
        .background = sidebar.host(selected, hovered).background,
        .corner_radius = 6,
    };
}

pub fn fileRowName(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 400, .line_height = 16.0 / 11.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}

pub fn fileRowDirectoryName(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 16.0 / 11.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}

pub fn fileAdd(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .font_weight = 500, .line_height = 14.0 / 10.0, .color = theme.current().ok_ink };
}

pub fn fileRemove(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .font_weight = 500, .line_height = 14.0 / 10.0, .color = theme.current().danger_ink };
}

pub const preview_default_height: f32 = 210;

pub fn previewTools() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 4, .padding = .{ .left = 5, .right = 3 } };
}

pub fn previewGrip() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 10 }, .flex_shrink = 0, .align_items = .center, .justify = .center, .margin = .{ .top = -5, .bottom = -5 }, .cursor = .ns_resize, .hit_behavior = .@"opaque" };
}

pub fn previewGripMark(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = 2 }, .flex_shrink = 0, .background = theme.current().fg_3, .border = .{ .width = 0, .radius = 1 }, .hit_behavior = .pass_through };
}

pub fn previewStatus() ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .flex_shrink = 0, .padding = .{ .left = 10, .right = 10, .top = 3, .bottom = 5 } };
}

pub fn preview(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .{ .px = preview_default_height },
        .flex_shrink = 0,
        .direction = .column,
        .background = theme.popupInset(),
        .border = .{ .width = 0, .radius = 8 },
        .overflow = .hidden,
        .overflow_hidden = true,
    };
}

pub fn previewHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 4, .padding = .{ .left = 8, .right = 6 } };
}

pub fn previewTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 500, .line_height = 15.0 / 10.5, .color = theme.current().fg_1, .text_overflow = .ellipsis };
}

pub fn previewSegment(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = 24 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 2, .padding = .{ .left = 2, .right = 2 }, .background = theme.popupInset(), .border = .{ .width = 0, .radius = 6 } };
}

pub fn previewSegmentButton(active: bool) ButtonStyle {
    return .{
        .height = .{ .px = 20 },
        .padding = .{ .left = 6, .right = 6 },
        .gap = 0,
        .font_size = 10,
        .font_weight = 500,
        .text_color = if (active) theme.current().fg_1 else theme.current().fg_2,
        .background = if (active) sidebar.hostSelection() else ui.Color.TRANSPARENT,
        .corner_radius = 4,
        .border = .{ .width = 0, .radius = 4 },
        .flex_shrink = 0,
    };
}

pub fn previewBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .direction = .row, .background = ui.Color.TRANSPARENT };
}

pub fn previewScroll(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .min_height = 0, .background = ui.Color.TRANSPARENT };
}

pub fn previewContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .direction = .row, .align_items = .start, .flex_shrink = 0 };
}

pub fn previewGutter(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .font_weight = 400, .line_height = 16.0 / 10.0, .color = theme.current().fg_3, .text_align = .end, .wrap = .newline_only, .selectable = false, .use_monospace_font = true };
}

pub fn previewCode(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_1, .wrap = .newline_only, .selectable = true, .use_monospace_font = true };
}

pub fn previewPlaceholder(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 1.6, .color = theme.current().fg_2, .wrap = .word, .text_align = .center };
}
