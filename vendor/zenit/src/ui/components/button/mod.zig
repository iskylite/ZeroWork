/// Button Component
///
/// View in button.yix, styles (ControlShell recipe + override) and paint in styles.yss.
///
/// Features:
/// - variant: primary, secondary, ghost, danger, link
/// - size: xs, sm, md, lg (ControlSize)
/// - icon: icon button (SVG asset or texture)
/// - loading: load state (spinning indicator, hide icon, no click)
/// - disabled: disabled state
/// - hover / press (held, pointer still inside) swap background, 150ms transition
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = core.Scope;
const reactive = @import("../../reactive.zig");
const svg_assets = @import("../../svg_assets.zig");
const events = @import("../../events.zig");
const control_shell = @import("../control_shell/mod.zig");

/// Button variant, alias to ControlVariant (compatible)
pub const ButtonVariant = control_shell.ControlVariant;

/// Button size, alias to ControlSize (compatible)
pub const ButtonSize = control_shell.ControlSize;

/// Create button: `W.Button(.{ .label = "Save", .disabled = ui.not(dirty), .on_click = cx.on(S, s,
/// S.save) })`
pub const Button = @import("_button.yix.zig").Button;
pub const ButtonProps = @import("_button.yix.zig").ButtonProps;
/// `Button(...)` return type (independent of arguments), for call sites that name element type
pub const ButtonBuilder = @TypeOf(Button(.{}));

// ===== Tests =====

fn findText(n: *Node, text: []const u8) ?*Node {
    if (n.getText()) |t| if (std.mem.eql(u8, t.content, text)) return n;
    for (n.children.items) |c| if (findText(c, text)) |r| return r;
    return null;
}

fn findTag(n: *Node, tag: core.ElementTag) ?*Node {
    for (n.children.items) |c| {
        if (c.tag == tag) return c;
        if (findTag(c, tag)) |r| return r;
    }
    return null;
}

/// Load indicator (self-drawn node)
fn findSpinner(n: *Node) ?*Node {
    for (n.children.items) |c| {
        if (c.meta.per_frame.custom_hooks.draw != null) return c;
        if (findSpinner(c)) |r| return r;
    }
    return null;
}

fn pressAt(cx: *Cx, node: ?*Node) void {
    cx.pressed_node = node;
    cx.notifyPressWatchers();
}

test "Button: basic creation" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Click Me", .variant = .primary, .size = .md }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    // Text in content slot (no icon: btn -> [content_slot -> text])
    try std.testing.expectEqual(@as(usize, 1), btn.children.items.len);
    const content_slot = btn.children.items[0];
    try std.testing.expectEqualStrings("Click Me", content_slot.children.items[0].getText().?.content);
    try std.testing.expectEqualStrings("Button", btn.meta.ownership.meta.component_name.?);
    try std.testing.expectEqual(core.A11yRole.button, btn.behavior.interaction.a11y.?.role);
    try std.testing.expectEqualStrings("Click Me", btn.behavior.interaction.a11y.?.label.?);
}

test "Button: parent Scope disposal detaches focus hooks before node teardown" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    var parent: ?*Scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer if (parent) |scope| scope.dispose();
    const btn = try Button(.{ .label = "New Local session" }).mount(parent.?, ctx);
    try root.appendChild(std.testing.allocator, btn);
    try std.testing.expect(btn.behavior.events.on_focus != null);
    try std.testing.expect(btn.behavior.events.on_blur != null);

    // The public component owns a child render scope and an outer node
    // binding. Disposing the parent releases the former before the latter.
    parent.?.dispose();
    parent = null;
    try std.testing.expect(btn.behavior.events.on_focus == null);
    try std.testing.expect(btn.behavior.events.on_blur == null);
    try std.testing.expect(btn.meta.per_frame.hooks.slots.focus_ring_anim == null);
    try std.testing.expect(btn.meta.ownership.scope.scope == null);

    ctx.detachChild(root, btn);
    ctx.destroyDetached(btn);
}

test "Button: variants" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    inline for (.{ ButtonVariant.primary, ButtonVariant.secondary, ButtonVariant.ghost, ButtonVariant.danger }) |v| {
        const btn = try Button(.{ .label = "Test", .variant = v }).mount(scope_val, ctx);
        try root.appendChild(std.testing.allocator, btn);
    }

    try std.testing.expectEqual(@as(usize, 4), root.children.items.len);
}

test "Button: click handler" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    var clicked = false;

    const btn = try Button(.{ .label = "Click", .on_click = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(c));
            ptr.* = true;
        }
    }.handler, &clicked) }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    ctx.layout();
    ctx.handleClick(btn.rectFromWorldOrFallback().x + 10, btn.rectFromWorldOrFallback().y + 10);

    try std.testing.expect(clicked);
}

test "Button: ghost icon-only stays bare (no forced chrome)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{
        .icon_only = true,
        .icon_asset = svg_assets.common.star,
        .variant = .ghost,
    }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    try std.testing.expect(Color.eql(btn.getBackground(), Color.TRANSPARENT));
    try std.testing.expect(btn.style.border.width == 0);
}

test "Button: 悬停 / 按下换底色（按下且指针仍在按钮内），禁用时没有交互态" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();
    const btn = try Button(.{ .label = "Go", .variant = .secondary }).mount(scope_val, ctx);
    defer ctx.freeNode(btn);
    const t = ctx.tokens;
    const cs = (control_shell.ControlShellConfig{ .variant = .secondary }).resolvedConditionalStyle(t).bgColors();
    const bg = struct {
        fn target(n: *Node) Color {
            const slot = n.frame_state.frame_local.runtime.transitions.?.find(.background).?;
            return if (slot.active) slot.to_color else n.getBackground();
        }
    }.target;
    try std.testing.expect(Color.eql(cs.normal, bg(btn)));
    btn.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(cs.hover, bg(btn)));
    pressAt(ctx, btn);
    try std.testing.expect(Color.eql(cs.pressed, bg(btn)));
    btn.behavior.events.on_leave.?.invoke(); // Press and drag out: back to normal
    try std.testing.expect(Color.eql(cs.normal, bg(btn)));
    pressAt(ctx, null);

    const off = try Button(.{ .label = "Off", .variant = .secondary, .disabled = true }).mount(scope_val, ctx);
    defer ctx.freeNode(off);
    try std.testing.expect(off.behavior.events.on_hover == null);
    try std.testing.expect(!off.behavior.interaction.focusable);
}

test "Button: label stays inside pill when placed in a stretch column" {
    // Regression: a fit-width Button directly under an align_items=.stretch
    // column (framework default) used to be stretched to the column width,
    // and its justify=center content got centered against that stretched
    // width, landing far outside the pill's own visual box (label looked
    // missing in Modal/Sheet/Form trigger buttons). no_cross_stretch fixes it.
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 200);

    // wide column with default align_items (.stretch)
    const col = try box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .direction = .column,
    }, .{});
    ctx.root = col;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Open Modal", .variant = .primary }).mount(scope_val, ctx);
    try col.appendChild(allocator, btn);

    ctx.layout();

    const br = btn.rectFromWorldOrFallback();
    // Button keeps intrinsic (fit) width, NOT stretched to the 800px column.
    try std.testing.expect(br.w < 400);

    // The content slot's rect is relative to the button: it must sit inside
    // the button's own box. (The previous version compared the label rect,
    // relative to the content slot, against the button rect, which was
    // vacuous: it passed even when the slot had drifted to x≈366.)
    const content_slot = btn.children.items[btn.children.items.len - 1];
    const sr = content_slot.rectFromWorldOrFallback();
    try std.testing.expect(sr.x >= -0.5);
    try std.testing.expect(sr.x + sr.w <= br.w + 0.5);
}

const CrossAlignProbe = struct {
    col_w: f32,
    btn_x: f32,
    btn_w: f32,
    slot_x: f32,
    slot_w: f32,

    fn expectLabelInside(self: @This()) !void {
        try std.testing.expect(self.slot_w > 0);
        try std.testing.expect(self.slot_x >= -0.5);
        try std.testing.expect(self.slot_x + self.slot_w <= self.btn_w + 0.5);
        // justify=center: content horizontally centered in button
        try std.testing.expectApproxEqAbs((self.btn_w - self.slot_w) / 2.0, self.slot_x, 0.5);
    }
};

/// 800px-wide column (specify align_items) with one Button, layout then return button rect relative
/// column (x/width).
fn probeButtonInColumn(align_items: core.AlignItems, block: bool) !CrossAlignProbe {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 200);

    const col = try box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .direction = .column,
        .align_items = align_items,
    }, .{});
    ctx.root = col;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Click me", .block = block }).mount(scope_val, ctx);
    try col.appendChild(allocator, btn);

    ctx.layout();

    const cr = col.rectFromWorldOrFallback();
    const br = btn.rectFromWorldOrFallback();
    // Content slot rect relative button itself: label must fall in button's own visible frame.
    const sr = btn.children.items[btn.children.items.len - 1].rectFromWorldOrFallback();
    return .{ .col_w = cr.w, .btn_x = br.x - cr.x, .btn_w = br.w, .slot_x = sr.x, .slot_w = sr.w };
}

test "Button: default stretch column keeps intrinsic width, start-aligned" {
    const r = try probeButtonInColumn(.stretch, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.btn_x, 0.5);
}

test "Button: parent align_items=.center centers a non-block button" {
    const r = try probeButtonInColumn(.center, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs((r.col_w - r.btn_w) / 2.0, r.btn_x, 0.5);
}

test "Button: parent align_items=.end end-aligns a non-block button" {
    const r = try probeButtonInColumn(.end, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(r.col_w - r.btn_w, r.btn_x, 0.5);
}

test "Button: parent align_items=.start start-aligns a non-block button" {
    const r = try probeButtonInColumn(.start, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.btn_x, 0.5);
}

test "Button: block button still fills the column width" {
    const stretch = try probeButtonInColumn(.stretch, true);
    try stretch.expectLabelInside();
    try std.testing.expectApproxEqAbs(stretch.col_w, stretch.btn_w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), stretch.btn_x, 0.5);
}

test "Button: mount (retained mode)" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    var clicked = false;
    const btn = try Button(.{ .label = "Retained Button", .variant = .primary, .size = .md, .on_click = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(c));
            ptr.* = true;
        }
    }.handler, &clicked) }).mount(scope_val, ctx);

    try root.appendChild(allocator, btn);

    // Validate node attributes (no icon: btn -> [content_slot])
    try std.testing.expect(findText(btn, "Retained Button") != null);
    try std.testing.expect(btn.meta.ownership.scope.scope != null);
    try std.testing.expect(btn.behavior.interaction.focusable);

    // Verify hover binding
    try std.testing.expect(btn.behavior.events.on_hover != null);

    // Simulate hover
    btn.behavior.events.on_hover.?.invoke();

    // Simulate click
    ctx.layout();
    ctx.handleClick(btn.rectFromWorldOrFallback().x + 10, btn.rectFromWorldOrFallback().y + 10);
    try std.testing.expect(clicked);

    // Scope dispose cleans all Signal/Effect
    scope_val.dispose();
}

test "Button: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("button", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Button(.{ .label = "Click Me", .variant = .primary, .size = .md }).mount(scope, cx);
        }
    }.m);
}

// ── Signal-first behavior ──

const ButtonFixture = struct {
    cx: *Cx,
    root: *Node,
    scope: *Scope,
    clicks: u32 = 0,

    fn init() !ButtonFixture {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
        cx.root = root;
        return .{ .cx = cx, .root = root, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(f: *ButtonFixture) void {
        f.scope.dispose();
        f.cx.deinit();
    }

    fn click(f: *ButtonFixture) void {
        f.clicks += 1;
    }

    fn mount(f: *ButtonFixture, b: anytype) !*Node {
        const n = try b.mount(f.scope, f.cx);
        try f.root.appendChild(std.testing.allocator, n);
        return n;
    }

    fn effects(f: *ButtonFixture) usize {
        return f.cx.owner.graph.countByKind().get(.effect);
    }
};

fn firstText(n: *Node) ?*Node {
    for (n.children.items) |c| {
        if (c.getText() != null) return c;
        if (firstText(c)) |r| return r;
    }
    return null;
}

fn textOf(btn: *Node) []const u8 {
    return firstText(btn).?.getText().?.content;
}

fn pressClick(btn: *Node) void {
    if (btn.behavior.events.on_click) |h| h.invoke();
}

test "Button: label, disabled and loading follow their sources" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const label = try f.scope.createText("Save", .{});
    const busy = try f.scope.createSignal(bool, false);
    const saving = try f.scope.createSignal(bool, false);
    const btn = try f.mount(Button(.{
        .label = label,
        .disabled = busy,
        .loading = saving,
        .icon_asset = svg_assets.common.star,
        .on_click = f.cx.on(ButtonFixture, &f, ButtonFixture.click),
    }));
    try std.testing.expectEqualStrings("Save", textOf(btn));
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);

    label.set("Save all changes");
    try std.testing.expectEqualStrings("Save all changes", textOf(btn));
    try std.testing.expectEqualStrings("Save all changes", btn.behavior.interaction.a11y.?.label.?);

    busy.set(true); // Disabled: click blocked, unfocusable
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);
    try std.testing.expect(!btn.behavior.interaction.focusable);
    try std.testing.expect(btn.behavior.interaction.a11y.?.disabled);
    busy.set(false);
    try std.testing.expect(btn.behavior.interaction.focusable);

    const icon = findTag(btn, .image).?;
    try std.testing.expect(findSpinner(btn) == null); // Not loading: no spinner
    saving.set(true); // Loading: spinner mounted, icon hidden, click blocked
    try std.testing.expect(findSpinner(btn) != null);
    try std.testing.expect(icon.style.display == .none);
    try std.testing.expect(btn.behavior.interaction.a11y.?.busy);
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);
    saving.set(false); // Load ends (hidden animation prevents idle forever-frame)
    try std.testing.expect(findSpinner(btn) == null);
    try std.testing.expect(icon.style.display != .none);
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 2), f.clicks);
}

test "Button: variant source switches the background and text color" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const active = try f.scope.createSignal(bool, false);
    const variant = reactive.map(active, struct {
        fn v(on: bool) ButtonVariant {
            return if (on) .primary else .ghost;
        }
    }.v);
    const btn = try f.mount(Button(.{ .label = "Bold", .variant = variant }));
    const bg = struct {
        fn target(n: *Node) Color {
            const slot = n.frame_state.frame_local.runtime.transitions.?.find(.background).?;
            return if (slot.active) slot.to_color else n.getBackground();
        }
    }.target;
    const ghost_bg = bg(btn);
    const ghost_text = findText(btn, "Bold").?.getText().?.color;
    active.set(true);
    try std.testing.expect(Color.eql(f.cx.tokens.tokens.color.button_primary_bg, bg(btn)));
    try std.testing.expect(!Color.eql(ghost_text, findText(btn, "Bold").?.getText().?.color));
    active.set(false);
    try std.testing.expect(Color.eql(ghost_bg, bg(btn)));
}

test "Button: static props add no effects (zero-cost static)" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const e0 = f.effects();
    _ = try f.mount(Button(.{ .label = "A" }));
    const plain = f.effects() - e0;
    const e1 = f.effects();
    _ = try f.mount(Button(.{ .label = "B", .variant = .danger, .disabled = false, .loading = false }));
    try std.testing.expectEqual(plain, f.effects() - e1);
}

test "Button: static loading mounts a spinner up front" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const btn = try f.mount(Button(.{ .label = "Working", .loading = true }));
    try std.testing.expect(findSpinner(btn) != null);
    try std.testing.expect(btn.behavior.interaction.a11y.?.busy);
}

test "button(loading signal): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("button(loading)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const loading = try scope.createSignal(bool, true);
            return try Button(.{ .label = "Busy", .loading = loading, .icon_asset = svg_assets.common.star }).mount(scope, cx);
        }
    }.m);
}

test "Button: static gating installs the caller's handler and context directly" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    var ctx_byte: u8 = 0;
    const ev = struct {
        fn h(_: events.Event, _: ?*anyopaque) events.EventResult {
            return .handled;
        }
    }.h;
    const btn = try f.mount(Button(.{ .label = "Send", .on_event = ev, .event_context = &ctx_byte, .on_click = f.cx.on(ButtonFixture, &f, ButtonFixture.click) }));
    // Caller (e.g. Notification) can overwrite event_context after mount; handler must be its own
    try std.testing.expect(btn.behavior.events.on_event.? == ev);
    try std.testing.expect(btn.behavior.events.event_context.? == @as(*anyopaque, &ctx_byte));
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);
}
