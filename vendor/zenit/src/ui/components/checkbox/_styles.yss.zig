//! Checkbox / Radio / Switch styling. Views in checkbox.yix / radio.yix / switch.yix,
//! logic in mod.zig.
const ui = @import("../../ui.zig");

/// Optional control dimensions preserve the existing 18 / 14 defaults.
pub fn checkboxSize(size: f32, _: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = size }, .height = .{ .px = size } };
}
pub fn checkboxCheckSize(size: f32, t: *const ui.ThemeTokens) ui.BoxStyle {
    return checkboxSize(@max(0, size - 4), t);
}
pub fn checkboxLabelSize(size: f32, _: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = size };
}

/// root: control + label row; track: 40x22 capsule; thumb: 18x18 slider (translate-x
/// positioned, motion and color same transition). Off/on: track switch-track-off <-> accent,
/// thumb switch-thumb <-> white (intentionally not theme), label secondary <-> primary.
/// disabled: all translucent, label stays secondary.
pub const SwitchParts = ui.sva(.{ .slots = .{ .root, .track, .thumb, .label, }, .base = .{ .root = .{ .width = .fit, .height = .fit, .gap = 8, .align_items = .center, .cursor = .pointer, }, .track = .{ .position = .relative, .width = 40, .height = 22, .corner_radius = 11, .transition = ui.transition("background 200ms ease-out-cubic"), }, .thumb = .{ .position = .absolute, .width = 18, .height = 18, .corner_radius = 9, .translate_y = 2, .shadow = .{ .offset_x = 0, .offset_y = 1, .blur = 2, .spread = 0, .color = ui.Color.rgba(0x00, 0x00, 0x00, 0x20) }, .transition = ui.transition("translate-x 200ms ease-out-cubic, background 200ms ease-out-cubic"), }, .label = .{ .font_size = 14, .transition = ui.transition("color 200ms ease-out-cubic"), }, }, .variants = .{ .checked = .{ .false = .{ .track = .{ .background = ui.tokenRef(.color, "switch-track-off"), }, .thumb = .{ .background = ui.tokenRef(.color, "switch-thumb"), .translate_x = 2, }, .label = .{ .color = ui.tokenRef(.color, "fg-secondary"), }, }, .true = .{ .track = .{ .background = ui.tokenRef(.color, "accent"), }, .thumb = .{ .background = ui.Color.hex(0xffffff), .translate_x = 20, }, .label = .{ .color = ui.tokenRef(.color, "fg-primary"), }, }, }, .disabled = .{ .false = .{ }, .true = .{ .root = .{ .opacity = 0.5, .cursor = .not_allowed, }, }, }, }, .defaults = .{ .checked = false, .disabled = false, }, .compound = .{ .{ .when = .{ .disabled = true, }, .style = .{ .label = .{ .color = ui.tokenRef(.color, "fg-secondary"), }, } }, }, });

/// root: control + label row; box: 18x18 frame (bg/border 150ms transition); check:
/// checkmark icon; indet: half-check overlay; label: label. Box bg/border = checked
/// (incl half) * disabled; disabled+checked uses special checkbox-disabled-checked-bg.
pub const CheckboxParts = ui.sva(.{ .slots = .{ .root, .box, .check, .indet, .label, }, .base = .{ .root = .{ .width = .fit, .height = .fit, .gap = 8, .align_items = .center, }, .box = .{ .width = 18, .height = 18, .border_width = 1.5, .corner_radius = 4, .justify = .center, .align_items = .center, .transition = ui.transition("background 150ms ease-out, border-color 150ms ease-out"), }, .check = .{ .width = 14, .height = 14, .icon_color = ui.tokenRef(.color, "button-primary-fg"), }, .indet = .{ .position = .absolute, .width = 18, .height = 18, .justify = .center, .align_items = .center, }, .label = .{ .font_size = 14, }, }, .variants = .{ .on = .{ .false = .{ }, .true = .{ }, }, .disabled = .{ .false = .{ .root = .{ .cursor = .pointer, }, .label = .{ .color = ui.tokenRef(.color, "fg-primary"), }, }, .true = .{ .root = .{ .cursor = .not_allowed, }, .label = .{ .color = ui.tokenRef(.color, "fg-secondary"), }, }, }, .shown = .{ .false = .{ .check = .{ .opacity = 0, }, .indet = .{ .opacity = 0, }, }, .true = .{ .check = .{ .opacity = 1, }, .indet = .{ .opacity = 1, }, }, }, }, .defaults = .{ .on = false, .disabled = false, .shown = false, }, .compound = .{ .{ .when = .{ .on = false, .disabled = false, }, .style = .{ .box = .{ .background = ui.tokenRef(.color, "checkbox-bg"), .border_color = ui.tokenRef(.color, "checkbox-border"), }, } }, .{ .when = .{ .on = true, .disabled = false, }, .style = .{ .box = .{ .background = ui.tokenRef(.color, "accent"), .border_color = ui.tokenRef(.color, "accent"), }, } }, .{ .when = .{ .on = false, .disabled = true, }, .style = .{ .box = .{ .background = ui.tokenRef(.color, "checkbox-disabled-bg"), .border_color = ui.tokenRef(.color, "checkbox-disabled-border"), }, } }, .{ .when = .{ .on = true, .disabled = true, }, .style = .{ .box = .{ .background = ui.tokenRef(.color, "checkbox-disabled-checked-bg"), .border_color = ui.tokenRef(.color, "checkbox-disabled-checked-bg"), }, } }, }, });

/// root: circle + label row (disabled = all translucent, selected color kept); circle:
/// 18x18 circle (bg/border 150ms transition); dot: checked inner dot (opacity 150ms
/// transition); label: label. RadioGroup option: unhovered shows circle border as accent on
/// hover (selected already accent).
pub const RadioParts = ui.sva(.{ .slots = .{ .root, .circle, .dot, .label, }, .base = .{ .root = .{ .width = .fit, .height = .fit, .gap = 8, .align_items = .center, }, .circle = .{ .width = 18, .height = 18, .border_width = 1.5, .corner_radius = ui.tokenRef(.radius, "full"), .justify = .center, .align_items = .center, .transition = ui.transition("background 150ms ease-out, border-color 150ms ease-out"), }, .dot = .{ .width = 9, .height = 9, .background = ui.tokenRef(.color, "fg-inverse"), .corner_radius = 4.5, .transition = ui.transition("opacity 150ms ease-out"), }, .label = .{ .font_size = 14, .color = ui.tokenRef(.color, "fg-primary"), }, }, .variants = .{ .checked = .{ .false = .{ .circle = .{ .background = ui.tokenRef(.color, "checkbox-bg"), .border_color = ui.tokenRef(.color, "checkbox-border"), }, .dot = .{ .opacity = 0, }, }, .true = .{ .circle = .{ .background = ui.tokenRef(.color, "accent"), .border_color = ui.tokenRef(.color, "accent"), }, .dot = .{ .opacity = 1, }, }, }, .disabled = .{ .false = .{ .root = .{ .opacity = 1, .cursor = .pointer, }, }, .true = .{ .root = .{ .opacity = 0.5, .cursor = .not_allowed, }, }, }, .hovered = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .checked = false, .disabled = false, .hovered = false, }, .compound = .{ .{ .when = .{ .checked = false, .hovered = true, }, .style = .{ .circle = .{ .border_color = ui.tokenRef(.color, "accent"), }, } }, }, });

pub const RadioGroupLayout = ui.cva(.{ .base = .{ .height = .fit, }, .variants = .{ .horizontal = .{ .false = .{ .direction = .column, .gap = 8, }, .true = .{ .direction = .row, .gap = 16, }, }, }, .defaults = .{ .horizontal = false, }, });

//# yix-map src/ui/components/checkbox/styles.yss
