const ui = @import("ui");
pub const theme = @import("../ui/app_theme.zig");
pub const ButtonStyle = @FieldType(ui.widgets.ControlShellConfig, "style");

/// The settings header stays mounted across page rebuilds. Repaint the public
/// Input shell after a late material/registry publication without replacing
/// its text, selection, focus or native composition client.
pub fn paintSearch(cx: *ui.Cx, input: *const ui.widgets.input.InputResult) void {
    const c = theme.current();
    input.state.tokens = cx.tokens;
    input.state.placeholder_color = c.fg_2;
    input.state.dirty = true;
    input.input_container.setBackground(c.well);
    input.input_container.setBorderColor(if (input.state.focused) c.accent else input.state.restingBorderColor());
    input.input_container.markRenderDirty();
}

pub const geometry = struct {
    pub const panel_width = @import("../ui/v3_geometry.zig").settings_width;
    pub const panel_height = @import("../ui/v3_geometry.zig").settings_height;
    pub const compact_height: f32 = 432;
    pub const card_padding: f32 = 10;
    pub const header_height: f32 = 62;
    pub const footer_height: f32 = 58;
    pub const header_gap: f32 = 6;
    // Frozen V3 settings owns a fixed page heading and footer around its scroll area.
    pub const viewport_gap: f32 = 0;
    pub const footer_gap: f32 = 0;
    pub const scrollbar_gutter: f32 = 16;
    pub const section_gap: f32 = 6;
    // Frozen V3 cards keep the description below their title in both fold states.
    pub const section_spacing: f32 = 10;
    pub const section_padding_x: f32 = 0;
    pub const section_padding_y: f32 = 0;
    pub const section_summary_header: f32 = 62;
    pub const section_title_line: f32 = 20;
    pub const section_icon: f32 = 18;
    pub const section_chevron: f32 = 14;
    pub const card_radius: f32 = 11;
    pub const section_radius: f32 = 11;
    pub const section_header: f32 = 28;
    pub const row_height: f32 = 52;
    pub const builtin_row_height: f32 = 44;
    pub const icon_button: f32 = 28;
    pub const footer_button: f32 = 34;
    pub const plugin_title_width: f32 = 236;
    pub const plugin_spacer_width: f32 = 24;
    pub const plugin_well_width: f32 = 164;
    pub const plugin_well_height: f32 = 30;
    pub const plugin_notice_icon: f32 = 16;
    pub const control_width: f32 = 220;
    pub const control_height: f32 = 32;
    pub const field_gap: f32 = 20;
    pub const help_button: f32 = 22;
    pub const switch_width: f32 = 30;
    pub const switch_height: f32 = 18;
    pub const switch_thumb: f32 = 14;
    pub const help_width: f32 = 292;
};

pub fn content(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{}, .background = theme.current().surface_1, .border = .{ .radius = geometry.card_radius }, .min_width = 0 };
}
pub fn header(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = geometry.header_height }, .direction = .row, .gap = geometry.header_gap, .align_items = .start, .padding = .{ .left = 5, .right = 5, .top = 4, .bottom = 16 }, .flex_shrink = 0 };
}
pub fn footer(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = header(undefined);
    style.height = .{ .px = geometry.footer_height };
    style.gap = 8;
    style.align_items = .center;
    style.padding = .{ .left = 5, .right = 5, .top = 12 };
    style.margin = .{ .top = geometry.footer_gap };
    return style;
}
pub fn title(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 600, .line_height = 20.0 / 13.0, .color = theme.current().fg_1 };
}

// Frozen V3 shared fields use 52px minimum rows and 220 × 32px controls;
// the compact panel narrows controls to 210px in the owning layout hook.
pub fn column(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = geometry.section_gap, .flex_shrink = 0, .min_width = 0 };
}
pub fn sectionColumn(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = column(t);
    style.gap = geometry.section_spacing;
    return style;
}
pub fn fieldRow(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(t);
    style.gap = geometry.field_gap;
    style.min_width = 0;
    return style;
}
pub fn fieldLabel(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .align_items = .start, .gap = 3 };
}
pub fn fieldControl(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = geometry.control_width }, .height = .{ .px = geometry.control_height }, .min_width = 0, .padding = .{ .left = 10, .right = 8 }, .background = theme.current().well, .border = .{ .width = 0, .radius = 8 }, .flex_shrink = 0 };
}
pub fn fieldButton() ButtonStyle {
    return .{ .width = .{ .px = geometry.control_width }, .height = .{ .px = geometry.control_height }, .padding = .{ .left = 10, .right = 8 }, .background = theme.current().well, .text_color = theme.current().fg_1, .corner_radius = 8, .border_width = 0, .font_size = 11.5, .font_weight = 400, .flex_shrink = 0 };
}
pub fn actionControl(danger: bool) ButtonStyle {
    return .{ .height = .{ .px = 32 }, .padding = .{ .left = 12, .right = 12 }, .background = theme.current().hover, .text_color = if (danger) theme.current().danger_ink else theme.current().fg_1, .font_size = 12, .font_weight = 500, .corner_radius = 8, .border_width = 0, .flex_shrink = 0 };
}
pub fn fieldHelpButton() ButtonStyle {
    var style = button(24, false);
    style.background = ui.Color.TRANSPARENT;
    return style;
}
pub fn fieldHelp(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = geometry.help_width }, .max_width = geometry.help_width, .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .gap = 6, .background = theme.current().overlay, .border = .{ .radius = 8 } };
}
pub fn tuneSelect(result: ui.widgets.SelectResult) void {
    tuneSelectText(result.content_slot);
}
fn tuneSelectText(node: *ui.Node) void {
    if (node.getText()) |old| {
        var text = old;
        text.font_size = 11.5;
        text.font_weight = 400;
        text.line_height = 17.0 / 11.5;
        text.color = theme.current().fg_1;
        node.setText(text);
    }
    for (node.children.items) |child| tuneSelectText(child);
}
pub fn tuneInput(input: *ui.widgets.input.InputResult) void {
    input.state.font_size = 11.5;
    input.state.line_height = 17;
    input.state.dirty = true;
    if (input.state.text_display_node) |node| if (node.getText()) |old| {
        var text = old;
        text.font_size = 11.5;
        text.line_height = 17.0 / 11.5;
        text.color = theme.current().fg_1;
        node.setText(text);
    };
    // Input's append slot is mounted before settings applies its compact font.
    // Keep units subordinate to the value rather than inheriting the default
    // widget's larger typography. The editable text keeps its own metrics.
    for (input.input_container.children.items) |slot| {
        if (input.state.text_display_node) |display| {
            var ancestor: ?*ui.Node = display;
            var editable = false;
            while (ancestor) |node| : (ancestor = node.parent) {
                if (node == slot) {
                    editable = true;
                    break;
                }
                if (node == input.input_container) break;
            }
            if (editable) continue;
        }
        tuneInputUnit(slot);
    }
}
fn tuneInputUnit(node: *ui.Node) void {
    if (node.getText()) |old| {
        var text = old;
        text.font_size = 11;
        text.font_weight = 400;
        text.line_height = 18.0 / 11.0;
        text.color = theme.current().fg_2;
        node.setText(text);
    }
    for (node.children.items) |child| tuneInputUnit(child);
}
pub fn providerInput(width: f32, height: f32) ui.BoxStyle {
    var style = fieldControl(undefined);
    style.width = if (width > 0) .{ .px = width } else .fill();
    style.height = .{ .px = height };
    style.flex = if (width > 0) 0 else 1;
    return style;
}
pub fn providerSelect() ButtonStyle {
    var style = fieldButton();
    style.width = .fill();
    style.height = .{ .px = 32 };
    style.flex = 1;
    return style;
}
pub fn paintSwitch(cx: *ui.Cx, node: *ui.Node, enabled: bool) void {
    node.setStyleInline(cx.allocator, .{ .width = .{ .px = geometry.switch_width }, .height = .{ .px = geometry.switch_height }, .gap = 0, .padding = .ZERO, .flex_shrink = 0 });
    const track = node.children.items[0];
    track.setStyleInline(cx.allocator, .{ .width = .{ .px = geometry.switch_width }, .height = .{ .px = geometry.switch_height }, .background = if (enabled) theme.current().accent else theme.current().border, .border = .{ .width = 0, .radius = 9 } });
    track.children.items[0].setStyleInline(cx.allocator, .{ .width = .{ .px = geometry.switch_thumb }, .height = .{ .px = geometry.switch_thumb }, .translate_x = if (enabled) 14 else 2, .translate_y = 0, .background = ui.Color.WHITE, .border = .{ .radius = 7 } });
}
pub fn shortcutGroup(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 };
}
pub fn shortcutButton(width: f32, compact: bool) ButtonStyle {
    var style = fieldButton();
    style.width = .{ .px = width };
    style.padding = .{ .left = if (compact) 3 else 10, .right = if (compact) 3 else 8 };
    return style;
}
pub fn label(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .font_weight = 500, .line_height = 1.5, .color = theme.current().fg_1 };
}
pub fn value(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 400, .line_height = 17.0 / 11.5, .color = theme.current().fg_2 };
}
pub fn note(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 400, .line_height = 16.0 / 10.5, .color = theme.current().fg_2 };
}
pub fn errorNote(t: *const ui.ThemeTokens) ui.TextStyle {
    var style = note(t);
    style.color = theme.current().danger_ink;
    style.wrap = .word;
    return style;
}
pub fn section(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .padding = .{ .left = geometry.card_padding, .right = geometry.card_padding, .top = geometry.card_padding, .bottom = geometry.card_padding }, .gap = geometry.section_gap, .background = ui.Color.TRANSPARENT, .border = .{ .radius = 0 }, .flex_shrink = 0, .min_width = 0 };
}
pub fn sectionState(expanded: bool) ui.BoxStyle {
    var style = section(undefined);
    style.padding = .{ .left = geometry.section_padding_x, .right = geometry.section_padding_x, .top = geometry.section_padding_y, .bottom = geometry.section_padding_y };
    style.border = .{ .radius = geometry.section_radius };
    _ = expanded;
    style.background = theme.current().surface_2;
    style.gap = 0;
    return style;
}
pub fn sectionHeading(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .fit = .{} }, .direction = .column, .gap = 2 };
}
pub fn sectionTitle(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .min_width = 0, .height = .{ .px = geometry.section_title_line }, .flex_shrink = 0, .font_size = 13, .font_weight = 650 };
}
pub fn summaryHeader(has_summary: bool) ui.BoxStyle {
    var style = sectionHeader(undefined);
    style.height = .{ .fit = .{} };
    style.min_height = if (has_summary) geometry.section_summary_header else 60;
    style.padding = .{ .left = 15, .right = 15, .top = 12, .bottom = 12 };
    style.gap = 10;
    return style;
}
pub fn sectionIcon(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = geometry.section_icon }, .height = .{ .px = geometry.section_icon }, .flex_shrink = 0, .align_self = .center };
}
pub fn sectionChevron(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = geometry.section_chevron }, .height = .{ .px = geometry.section_chevron }, .flex_shrink = 0 };
}
pub fn sectionHeader(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = geometry.section_header }, .direction = .row, .align_items = .center, .gap = geometry.section_gap, .flex_shrink = 0 };
}
pub fn row(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = geometry.row_height, .padding = .{ .top = 8, .bottom = 8 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 };
}
pub fn notice(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(undefined);
    style.height = .{ .px = geometry.section_header };
    return style;
}
pub fn button(size: f32, primary: bool) ButtonStyle {
    const colors = theme.current();
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .padding = .ZERO, .background = if (primary) colors.accent else colors.surface_2, .text_color = if (primary) ui.Color.WHITE else colors.fg_2, .corner_radius = if (primary) 8 else 7, .border_width = 0 };
}
pub fn textButton() ButtonStyle {
    return .{ .height = .{ .px = geometry.section_header }, .padding = .{ .left = 8, .right = 8 }, .background = theme.current().surface_2, .text_color = theme.current().fg_2, .corner_radius = 7, .border_width = 0, .font_size = 11.5, .font_weight = 400 };
}
pub fn buttonHover() ButtonStyle {
    return .{ .background = theme.current().hover };
}

// Protocol-planning facts share the Figma row geometry without turning a
// not-yet-released version/ABI or example value into an editable Config field.
pub fn pluginTag(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 22 }, .min_width = 42, .padding = .{ .left = 8, .right = 8 }, .background = theme.current().surface_2, .border = .{ .width = 0, .radius = 6 }, .flex_shrink = 0 };
}
pub fn pluginTagLabel(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .font_weight = 500, .line_height = 15.0 / 10.5, .color = theme.current().fg_2 };
}
pub fn pluginHeaderTitle(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = geometry.plugin_title_width }, .flex = 0, .flex_shrink = 1, .min_width = 0, .font_size = 12, .font_weight = 500 };
}
pub fn pluginCardDepth(_: *const ui.ThemeTokens) ui.BoxStyle {
    // DESIGN_STANDARDS §3.3 shadow-2. Keep the native shadow primitive;
    // Figma's five editable falloff shapes are a visual approximation of it.
    const dark = theme.currentName() == .dark;
    return .{ .shadow = .{ .blur = if (dark) 4 else 3, .offset_y = 1, .color = theme.current().shadow.withAlpha(if (dark) 89 else 13) } };
}
pub fn pluginPermissionLabel(t: *const ui.ThemeTokens) ui.TextStyle {
    var style = label(t);
    style.font_size = 11.5;
    style.line_height = 18.0 / 11.5;
    return style;
}
pub fn pluginHeaderSpacer(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = geometry.plugin_spacer_width }, .height = .{ .px = 1 }, .flex_shrink = 0 };
}
pub fn pluginHeaderSummary(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .min_width = 0, .font_size = 10.5, .font_weight = 400 };
}
pub fn pluginField(_: *const ui.ThemeTokens) ui.BoxStyle {
    var style = row(undefined);
    style.gap = geometry.section_gap;
    return style;
}
pub fn pluginReadOnlyWell(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .px = geometry.plugin_well_width },
        .height = .{ .px = geometry.plugin_well_height },
        .flex_shrink = 0,
        .direction = .row,
        .align_items = .center,
        .gap = geometry.section_gap,
        .padding = .{ .left = 10, .right = 8 },
        .background = theme.current().well,
        .border = .{ .radius = 8 },
    };
}
pub fn pluginReadOnlyValue(t: *const ui.ThemeTokens) ui.TextStyle {
    var style = value(t);
    style.color = theme.current().fg_1;
    return style;
}

pub const PluginNoticeTone = enum { neutral, danger, warning, accent };
pub fn pluginNoticeIconColor(tone: PluginNoticeTone) ui.Color {
    const c = theme.current();
    return switch (tone) {
        .neutral => c.fg_2,
        .danger => c.danger,
        .warning => c.warn,
        .accent => c.accent,
    };
}
pub fn pluginNoticeText(tone: PluginNoticeTone) ui.TextStyle {
    var style = note(undefined);
    // These notice inks are the actual per-theme Figma text roles; their
    // contrast differs from the adjacent icon's stronger status color.
    style.color = switch (tone) {
        .neutral => switch (theme.currentName()) {
            .dark => ui.Color.hex(0xa1a1aa),
            .light => ui.Color.hex(0x52525b),
            .sauber => ui.Color.hex(0x425b4b),
        },
        .danger => if (theme.currentName() == .dark) ui.Color.hex(0xff8585) else ui.Color.hex(0xa72c2c),
        .warning => if (theme.currentName() == .dark) ui.Color.hex(0xfbbf24) else ui.Color.hex(0x865609),
        .accent => switch (theme.currentName()) {
            .dark => ui.Color.hex(0xa5a7ff),
            .light => ui.Color.hex(0x4235bd),
            .sauber => ui.Color.hex(0x1345b8),
        },
    };
    return style;
}

pub fn sectionSummary(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .font_weight = 400, .line_height = 16.0 / 11.0, .color = theme.current().fg_2, .wrap = .word };
}

// Frozen V3 model row and native dialog layout.
pub fn modelListRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 44 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 }, .background = theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0, .min_width = 0 };
}
pub fn modelDialogHeader() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 67 }, .direction = .row, .align_items = .center, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 10 }, .flex_shrink = 0 };
}
pub fn modelDialogContent() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 16, .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 18 }, .flex_shrink = 0 };
}
pub fn modelDialogFooter() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 60 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 20, .right = 20, .top = 12, .bottom = 16 }, .flex_shrink = 0 };
}
pub fn modelDialogButton(primary: bool) ButtonStyle {
    var style = textButton();
    style.width = .{ .px = 88 };
    style.height = .{ .px = 32 };
    style.background = if (primary) theme.current().accent else theme.current().well;
    style.text_color = if (primary) ui.Color.WHITE else theme.current().fg_1;
    return style;
}
pub fn modelCapabilities() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = ui.Padding.all(12), .background = theme.current().surface_2, .border = .{ .radius = 9 }, .flex_shrink = 0 };
}
pub fn modelCapabilityRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 53 }, .direction = .row, .align_items = .center, .flex_shrink = 0 };
}

/// Keep stock control labels on the application's theme after its style bindings settle.
/// Interaction, focus and checked state remain owned by the native widget.
pub fn paintControlText(node: *ui.Node) void {
    if (node.getText()) |text| if (!@import("std").meta.eql(text.color, theme.current().fg_1)) node.setTextColor(theme.current().fg_1);
    for (node.children.items) |child| paintControlText(child);
}
