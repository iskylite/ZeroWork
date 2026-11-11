//! Connection-method choices and the editable topology shared by connection editors.
const std = @import("std");
const ui = @import("ui");
const S = @import("../../ui/wizard_styles.zig");
const route_hop = @import("route_hop_control.zig");
const RoutePicker = @import("route_picker.zig").RoutePicker;

const route_endpoint_height: f32 = 46;
const trigger_ids = indexedIds("wizard.route.hop.{d}", 8);
const menu_ids = indexedIds("wizard.route.menu.{d}", 8);
const insert_ids = indexedIds("wizard.route.insert.{d}", 9);

fn indexedIds(comptime format: []const u8, comptime count: usize) [count][]const u8 {
    var ids: [count][]const u8 = undefined;
    inline for (0..count) |index| ids[index] = std.fmt.comptimePrint(format, .{index});
    return ids;
}

pub const Props = struct {
    locked: *ui.Signal(bool),
    insert_disabled: *ui.Signal(bool),
    direct: ui.Handler(void),
    ssh: ui.Handler(void),
    hop_actions: route_hop.Actions,
    picker_actions: RoutePicker.Actions,
    target_role: []const u8 = "目标主机",
    target_icon: ui.SvgAsset = ui.icons.server,
};

pub const Choice = struct { root: *ui.Node, title: *ui.Node, mark: *ui.Node };
pub const Preview = struct {
    row: ?*ui.Node = null,
    nodes: [10]?*ui.Node = @splat(null),
    names: [10]?*ui.Node = @splat(null),
    addresses: [10]?*ui.Node = @splat(null),
    users: [10]?*ui.Node = @splat(null),
    arrows: [9]?*ui.Node = @splat(null),

    pub fn setCount(self: *const Preview, count: usize) void {
        for (self.nodes, 0..) |node, index| if (node) |entry| {
            entry.setDisplay(if (index == 0 or index == 9 or index <= count) .flex else .none);
        };
        for (self.arrows, 0..) |node, index| if (node) |entry| {
            entry.setDisplay(if (index <= count) .flex else .none);
        };
    }
};

pub const View = struct {
    cx: *ui.Cx,
    props: Props,
    root: *ui.Node,
    card: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    picker: *RoutePicker = undefined,
    preview: Preview = .{},
    roles: [10]?*ui.Node = @splat(null),
    edges: [9]?Edge = @splat(null),
    controls: [8]?*route_hop.RouteHopControl = @splat(null),
    choices: [2]?Choice = @splat(null),
    vertical: ?bool = null,
    count: usize = 0,

    pub fn setRoute(self: *View, ssh: bool, count: usize) void {
        self.count = count;
        self.paintChoices(ssh);
        self.scroll.container.setDisplay(if (ssh) .flex else .none);
        self.preview.setCount(count);
        for (self.controls) |slot| if (slot) |control| control.refresh(count);
        self.picker.dirty = true;
    }

    pub fn close(self: *View) void {
        self.picker.close();
        for (self.controls) |slot| if (slot) |control| control.menu_open.?.set(false);
    }

    pub fn reveal(self: *View, index: usize) void {
        if (index >= self.count) return;
        const area = self.scroll;
        area.state.content_height = area.content.globalRect().h;
        area.state.viewport_height = area.container.globalRect().h;
        ui.widgets.scrollIntoView(area.state, area.content, self.preview.nodes[index + 1].?, .nearest);
    }

    pub fn paint(self: *View, ssh: bool) void {
        const colors = S.theme.current();
        self.paintChoices(ssh);
        self.scroll.container.setBackground(S.theme.popupInset());
        const endpoint_fill = S.routeEndpointFill();
        self.preview.nodes[0].?.setBackground(endpoint_fill);
        self.preview.nodes[9].?.setBackground(endpoint_fill);
        for (self.preview.names) |node| node.?.setTextColor(colors.fg_1);
        for (self.preview.addresses) |node| node.?.setTextColor(colors.fg_2);
        for (self.roles) |node| if (node) |label| label.setTextColor(colors.fg_3);
        for (self.edges) |slot| if (slot) |edge| edge.paint();
        self.picker.paint();
    }

    pub fn layout(self: *View, vertical: bool, height: f32) bool {
        const area = self.scroll;
        var changed = false;
        if (area.container.style.height != .px or area.container.style.height.px != height) {
            area.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
            if (naturalHeight(self.count, vertical) > height) area.state.onScrollActivity();
            changed = true;
        }
        if (self.vertical != vertical) {
            self.vertical = vertical;
            area.content.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = if (vertical) .column else .row, .align_items = .center, .gap = 0, .padding = .{ .left = 12, .right = if (vertical) 16 else 12, .top = 6, .bottom = 6 } });
            for (self.preview.nodes, 0..) |entry, index| if (entry) |node| {
                const hop = index != 0 and index != 9;
                var style = S.row(if (!vertical) 56 else if (hop) 52 else route_endpoint_height);
                style.padding = .{ .left = 10, .right = 8 };
                style.gap = 9;
                if (!vertical and index == 0) style.width = .{ .px = 110 };
                if (!vertical and hop) style.width = .{ .px = 216 };
                if (!vertical and index == 9) style.flex = 1;
                style.min_width = 0;
                style.border = .{ .radius = 7 };
                node.setStyleInline(self.cx.allocator, style);
            };
            for (self.edges) |entry| if (entry) |edge| edge.layout(self.cx, vertical);
            ui.widgets.setScrollY(area.state, area.content, 0);
            changed = true;
        }
        return changed;
    }

    pub fn paintChoices(self: *View, ssh: bool) void {
        self.card.setBackground(if (ssh) S.theme.popupSelection() else ui.Color.TRANSPARENT);
        for (self.choices, 0..) |entry, index| if (entry) |choice| {
            const selected = ssh == (index == 1);
            paintIcon(choice.mark, if (selected) ui.icons.circle_dot else ui.icons.circle, 14, if (selected) S.theme.current().accent else S.theme.current().fg_2);
            choice.title.setTextColor(if (selected) S.theme.current().accent_ink else S.theme.current().fg_1);
            if (choice.root.behavior.interaction.a11y) |*access| access.pressed = selected;
        };
    }
};

pub fn isVertical(count: usize, viewport_width: f32) bool {
    return count > 1 or @min(S.width, S.availableModalWidth(viewport_width)) < 728;
}

pub fn naturalHeight(count: usize, vertical: bool) f32 {
    if (count == 0) return 0;
    if (!vertical) return 68;
    const jumps: f32 = @floatFromInt(count);
    return 12 + 2 * route_endpoint_height + jumps * 52 + (jumps + 1) * 38;
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, props: Props) !*View {
    const root = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .flex_shrink = 0 }, .{});
    const card = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .border = .{ .radius = 12 }, .flex_shrink = 0 }, .{});
    const view = try scope.createState(View, .{ .cx = cx, .props = props, .root = root, .card = card });
    view.choices[0] = try mountAccessChoice(cx, scope, root, 40, "从本机直接连接", "wizard.access.direct", props.locked, props.direct);
    card.meta.ownership.meta.test_id = "wizard.route.card";
    try root.appendChild(cx.allocator, card);
    view.choices[1] = try mountAccessChoice(cx, scope, card, 43, "经 SSH 跳板连接", "wizard.access.jump", props.locked, props.ssh);

    const area = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
    area.container.meta.ownership.meta.test_id = "wizard.route.chain";
    area.container.setStyleInline(cx.allocator, .{ .width = .{ .grow = .{} }, .height = .{ .px = 68 }, .margin = .{ .left = 16, .right = 16, .bottom = 16 }, .background = S.theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0 });
    try view.card.appendChild(cx.allocator, area.container);
    view.scroll = area;
    const preview = &view.preview;
    preview.row = area.content;

    const endpoint_fill = S.routeEndpointFill();
    for (0..10) |i| {
        if (i > 0) {
            const edge = try Edge.mount(cx, scope, view, i - 1);
            view.edges[i - 1] = edge;
            preview.arrows[i - 1] = edge.root;
            try area.content.appendChild(cx.allocator, edge.root);
        }
        const hop = i > 0 and i < 9;
        var style = S.row(52);
        if (!hop) style.background = endpoint_fill;
        const node = try ui.box(cx, style, .{});
        preview.nodes[i] = node;
        if (i == 9) node.meta.ownership.meta.test_id = "wizard.route.target";
        try area.content.appendChild(cx.allocator, node);
        const main = if (hop) blk: {
            const index = i - 1;
            const control = try route_hop.RouteHopControl.mount(cx, scope, .{
                .row = node,
                .index = index,
                .trigger_id = trigger_ids[index],
                .menu_id = menu_ids[index],
                .locked = props.locked,
                .actions = props.hop_actions,
            });
            view.controls[index] = control;
            break :blk control.trigger;
        } else node;
        const asset = if (i == 0) ui.icons.laptop else if (hop) ui.icons.server else props.target_icon;
        const icon = if (hop) try S.theme.icon(cx, asset, "accent", S.icon(24)) else try S.theme.icon(cx, asset, "fg_2", S.icon(24));
        try main.appendChild(cx.allocator, icon);
        const labels = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .flex = 1, .min_width = 0, .gap = 1 }, .{});
        try main.appendChild(cx.allocator, labels);
        if (i != 0) {
            var buffer: [24]u8 = undefined;
            const role = if (hop) try std.fmt.bufPrint(&buffer, "跳板 {d}", .{i}) else props.target_role;
            var role_style = S.text(10, 500, false);
            role_style.line_height = 12.0 / 10.0;
            role_style.color = S.theme.current().fg_3;
            const label = try ui.text(cx, role, role_style);
            view.roles[i] = label;
            try labels.appendChild(cx.allocator, label);
        }
        var name_style = S.text(13, 600, false);
        name_style.line_height = 17.0 / 13.0;
        var address_style = S.text(10.5, 400, true);
        address_style.line_height = 13.0 / 10.5;
        preview.names[i] = try ui.text(cx, if (i == 0) "本机" else "", name_style);
        preview.addresses[i] = try ui.text(cx, if (i == 0) "127.0.0.1" else "", address_style);
        for ([_]*ui.Node{ preview.names[i].?, preview.addresses[i].? }) |label| {
            label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
            try labels.appendChild(cx.allocator, label);
        }
    }
    view.picker = try RoutePicker.mount(cx, scope, root, .{
        .context = view,
        .options = pickerOptions,
        .available = pickerAvailable,
        .choose = pickerChoose,
        .anchor_gap = pickerAnchorGap,
        .anchor_changed = pickerAnchorChanged,
    });
    return view;
}

fn pickerOptions(raw: *anyopaque, target: RoutePicker.Target) []const ui.widgets.SelectOption {
    const self: *View = @ptrCast(@alignCast(raw));
    const actions = self.props.picker_actions;
    return actions.options(actions.context, target);
}

fn pickerAvailable(raw: *anyopaque, target: RoutePicker.Target, value: []const u8) bool {
    const self: *View = @ptrCast(@alignCast(raw));
    const actions = self.props.picker_actions;
    return actions.available(actions.context, target, value);
}

fn pickerChoose(raw: *anyopaque, target: RoutePicker.Target, value: []const u8) void {
    const self: *View = @ptrCast(@alignCast(raw));
    const actions = self.props.picker_actions;
    actions.choose(actions.context, target, value);
}

fn pickerAnchorGap(raw: *anyopaque, target: RoutePicker.Target) f32 {
    const self: *View = @ptrCast(@alignCast(raw));
    const actions = self.props.picker_actions;
    if (actions.anchor_gap) |get| return get(actions.context, target);
    return if (target == .insert and self.vertical == false) 12 else 0;
}

fn pickerAnchorChanged(raw: *anyopaque, target: RoutePicker.Target, active: bool) void {
    const self: *View = @ptrCast(@alignCast(raw));
    if (self.props.picker_actions.anchor_changed) |changed| changed(self.props.picker_actions.context, target, active);
    const index = switch (target) {
        .insert => |index| index,
        .replace => return,
    };
    const edge = self.edges[index].?;
    if (active) {
        const colors = S.theme.current();
        edge.badge.setBackground(colors.accent);
        _ = edge.icon.setTint(S.theme.patchInk(colors.overlay, &.{colors.accent}));
    } else edge.paint();
}

fn mountAccessChoice(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, height: f32, title: []const u8, id: []const u8, locked: *ui.Signal(bool), click: ui.Handler(void)) !Choice {
    var style = S.row(height);
    style.padding = .{ .left = 16 };
    style.gap = 10;
    style.justify = .start;
    style.background = ui.Color.TRANSPARENT;
    const root = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = title, .disabled = locked, .base_style = style, .on_click = click }).mount(scope, cx);
    root.meta.ownership.meta.test_id = id;
    for (root.children.items) |child| child.setDisplay(.none);
    root.setStyleInline(cx.allocator, style);
    const mark = try ui.iconTint(cx, ui.icons.circle, S.theme.current().fg_2, S.icon(14));
    try root.appendChild(cx.allocator, mark);
    const heading = try ui.text(cx, title, S.text(13, 600, false));
    heading.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    try root.appendChild(cx.allocator, heading);
    try parent.appendChild(cx.allocator, root);
    return .{ .root = root, .title = heading, .mark = mark };
}

fn paintIcon(node: *ui.Node, asset: ui.SvgAsset, size: f32, tint: ui.Color) void {
    if (asset.icon_id) |id| if (asset.pickRep(size)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = tint });
}

const Edge = struct {
    root: *ui.Node,
    width: f32,
    line: *ui.Node,
    arrow: *ui.Node,
    button: *ui.Node,
    badge: *ui.Node,
    icon: *ui.Node,

    fn mount(cx: *ui.Cx, scope: *ui.Scope, view: *View, index: usize) !Edge {
        const context = try scope.createState(Insert, .{ .view = view, .index = index });
        const root = try ui.box(cx, .{}, .{});
        const line = try ui.box(cx, .{ .hit_behavior = .pass_through }, .{});
        const arrow = try ui.iconTint(cx, ui.icons.chevron_right, S.theme.current().fg_2, S.icon(14));
        try root.appendChild(cx.allocator, line);
        try root.appendChild(cx.allocator, arrow);
        var style = S.button(24, 24, false);
        style.background = ui.Color.TRANSPARENT;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "在此处添加跳板", .disabled = view.props.insert_disabled, .base_style = style, .on_click = cx.on(Insert, context, Insert.click) }).mount(scope, cx);
        for (button.children.items) |child| child.setDisplay(.none);
        button.setStyleInline(cx.allocator, style);
        context.anchor = button;
        button.meta.ownership.meta.test_id = insert_ids[index];
        const badge = try ui.box(cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .border = .{ .radius = 8 }, .align_items = .center, .justify = .center, .background = S.theme.popupSelection(), .hit_behavior = .pass_through }, .{});
        const icon = try ui.iconTint(cx, ui.icons.plus, S.theme.current().accent, S.icon(12));
        try badge.appendChild(cx.allocator, icon);
        try button.appendChild(cx.allocator, badge);
        try root.appendChild(cx.allocator, button);
        return .{ .root = root, .width = if (index == 0) 74 else 54, .line = line, .arrow = arrow, .button = button, .badge = badge, .icon = icon };
    }

    fn layout(self: Edge, cx: *ui.Cx, vertical: bool) void {
        self.root.setStyleInline(cx.allocator, .{ .width = if (vertical) .fill() else .{ .px = self.width }, .height = .{ .px = if (vertical) 38 else 56 }, .flex_shrink = 0 });
        self.line.setStyleInline(cx.allocator, .{
            .position = .absolute,
            .inset = if (vertical) .{ .left = .{ .px = 21 }, .top = .{ .px = 3 } } else .{ .left = .{ .px = 3 }, .top = .{ .px = 28 } },
            .width = .{ .px = if (vertical) 1.35 else self.width - 10 },
            .height = .{ .px = if (vertical) 29 else 1.35 },
        });
        self.arrow.setStyleInline(cx.allocator, .{
            .position = .absolute,
            .inset = if (vertical) .{ .left = .{ .px = 15 }, .top = .{ .px = 24 } } else .{ .left = .{ .px = self.width - 15 }, .top = .{ .px = 22 } },
            .width = .{ .px = 14 },
            .height = .{ .px = 14 },
        });
        paintIcon(self.arrow, if (vertical) ui.icons.chevron_down else ui.icons.chevron_right, 14, S.theme.current().fg_2);
        self.button.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = if (vertical) 23 else self.width / 2 - 12 }, .top = .{ .px = if (vertical) 7 else 2 } } });
        self.paint();
    }

    fn paint(self: Edge) void {
        const colors = S.theme.current();
        const surface = S.theme.popupInset();
        const line = ui.Color.lerp(colors.fg_2, surface, 0.22);
        self.line.setBackground(line);
        _ = self.arrow.setTint(line);
        self.badge.setBackground(ui.Color.lerp(surface, colors.accent, 0.24));
        _ = self.icon.setTint(colors.fg_1);
    }
};

const Insert = struct {
    view: *View,
    index: usize,
    anchor: *ui.Node = undefined,

    fn click(self: *Insert) void {
        const view = self.view;
        if (view.props.locked.peek() or view.props.insert_disabled.peek() or self.index > view.count) return;
        view.picker.show(self.anchor, .{ .insert = self.index });
    }
};
