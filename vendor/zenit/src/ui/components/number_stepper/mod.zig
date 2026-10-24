/// NumberStepper - numeric stepper (B5): [-] 42 [+]
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;
const EventResult = core.EventResult;
const view = @import("../../view.zig");

pub const NumberStepperProps = struct {
    /// current value: `f64` uncontrolled initial; `*Signal(f64)` controlled (interactions write
    /// directly); `ui.split` intercepts. out-of-bounds external values display clamped, not written
    /// back.
    value: Model(f64) = .{ .local = 0 },
    min: ?f64 = null,
    max: ?f64 = null,
    step: f64 = 1,
    width: f32 = 140,
    disabled: Source(bool) = .{ .value = false },
    /// called after user steps and lands (landed value)
    on_change: ?Handler(f64) = null,
};

/// NumberStepper runtime (scope-owned): view = f(value, disabled)
pub const NumberStepperRuntime = struct {
    value: reactive.Bound(f64),
    disabled: Source(bool),
    on_change: ?Handler(f64),
    min: ?f64,
    max: ?f64,
    step: f64,
    /// current displayed value (data value clamped to range)
    shown: f64 = 0,
    is_disabled: bool = false,
    value_node: *Node,
    minus: *Node,
    plus: *Node,
    /// wrapper node: a11y numeric value for role=spinbutton lives here
    wrapper_node: *Node,
    cx: *Cx,

    fn clampValue(self: *const NumberStepperRuntime, v: f64) f64 {
        var out = v;
        if (self.min) |m| out = @max(out, m);
        if (self.max) |m| out = @min(out, m);
        return out;
    }

    fn view(self: *NumberStepperRuntime, comptime tracked: bool) !void {
        const v = self.clampValue(self.value.readAs(tracked));
        const dis = self.disabled.read(tracked);
        if (dis != self.is_disabled) {
            self.is_disabled = dis;
            self.applyDisabled();
        }
        // NaN != NaN: first time (shown is NaN sentinel) and external NaN write both trigger,
        // latter formats once
        if (v != self.shown and !(std.math.isNan(v) and std.math.isNan(self.shown))) {
            self.shown = v;
            try self.syncLabel();
        }
    }

    fn viewEffect(self: *NumberStepperRuntime) void {
        self.view(true) catch |err| std.log.err("[NumberStepper] update failed: {}", .{err});
    }

    fn applyDisabled(self: *NumberStepperRuntime) void {
        const dis = self.is_disabled;
        const t = self.cx.tokens;
        self.wrapper_node.setFocusable(!dis);
        if (self.wrapper_node.behavior.interaction.a11y) |*a| a.disabled = dis;
        for ([_]*Node{ self.minus, self.plus }) |btn| {
            btn.style.cursor = if (dis) .default else .pointer;
            if (btn.behavior.interaction.a11y) |*a| a.disabled = dis;
            const label = btn.children.items[0];
            if (label.getText()) |old| {
                var txt = old;
                txt.color = styles.stepBtnLabelStyle(dis, t).color;
                label.setText(txt);
            }
            btn.markRenderDirty();
        }
        if (self.value_node.getText()) |old| {
            var txt = old;
            txt.color = styles.stepperValueStyle(dis, t).color;
            self.value_node.setText(txt);
        }
        self.value_node.markRenderDirty();
    }

    fn syncLabel(self: *NumberStepperRuntime) !void {
        // integer step + integer value -> no decimal display. @intFromFloat panics on inf / |v| >=
        // 2^63: values outside i64 range use float format
        var buf: [32]u8 = undefined;
        const fits_i64 = std.math.isFinite(self.shown) and @abs(self.shown) < 0x1p63;
        const is_int = fits_i64 and self.shown == @trunc(self.shown) and self.step == @trunc(self.step);
        const label = if (is_int)
            std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(self.shown))}) catch "?"
        else
            std.fmt.bufPrint(&buf, "{d:.2}", .{self.shown}) catch "?";
        try self.value_node.setTextContent(self.cx.allocator, label);
        self.value_node.markRenderDirty();

        // min/max when absent filled with current value, indicates that direction unbounded, better
        // than reporting 0: reporting 0 makes AT think 'already at limit'. value_text points to
        // text copy owned by node.
        if (self.wrapper_node.behavior.interaction.a11y) |*a| {
            a.value_now = @floatCast(self.shown);
            a.value_min = @floatCast(self.min orelse self.shown);
            a.value_max = @floatCast(self.max orelse self.shown);
            a.value_text = self.value_node.getText().?.content;
            if (a.value_range) |*range| {
                range.now = @floatCast(self.shown);
                range.min = @floatCast(self.min orelse self.shown);
                range.max = @floatCast(self.max orelse self.shown);
            }
        }
    }

    /// user input: clamped to range then proposed; landing calls on_change (last step, may destroy
    /// component)
    fn propose(self: *NumberStepperRuntime, raw: f64) void {
        if (self.is_disabled or std.math.isNan(raw)) return;
        const landed = self.value.commit(self.clampValue(raw)) orelse return;
        if (self.on_change) |h| h.call(landed);
    }

    /// step baseline: when external writes NaN (shows as NaN only if unbounded) start from min or
    /// 0, else keys fail
    fn base(self: *const NumberStepperRuntime) f64 {
        return if (std.math.isNan(self.shown)) self.min orelse 0 else self.shown;
    }

    fn increment(self: *NumberStepperRuntime) void {
        self.propose(self.base() + self.step);
    }

    fn decrement(self: *NumberStepperRuntime) void {
        self.propose(self.base() - self.step);
    }
};

/// returns true if control handled request (caller focuses based on this)
fn setA11yStepperValue(context: *anyopaque, value: f32) bool {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(context));
    if (rt.is_disabled) return false;
    rt.propose(value);
    return true;
}

pub const NumberStepperResult = struct {
    wrapper: *Node,
    /// value signal (`ui.split` = null)
    value: ?*Signal(f64),
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: NumberStepperResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

fn onMinus(ctx: *anyopaque) void {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(ctx));
    rt.decrement();
}

fn onPlus(ctx: *anyopaque) void {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(ctx));
    rt.increment();
}

fn onStepKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    if (rt.is_disabled) return .ignored;
    switch (key) {
        .right, .up => rt.increment(),
        .left, .down => rt.decrement(),
        else => return .ignored,
    }
    return .handled;
}

// styling extracted to styles.zig
const styles = @import("styles.zig");
const stepBtnStyle = styles.stepBtnStyle;
const stepBtnLabelStyle = styles.stepBtnLabelStyle;
const stepperWrapperStyle = styles.stepperWrapperStyle;
const stepperValueStyle = styles.stepperValueStyle;

const StepBtnProps = struct { style: core.BoxStyle, a11y: core.A11yProps, on_click: core.HandlerRef };
const StepLabelProps = struct { style: core.TextStyle };

fn stepBtn(t: *const core.ThemeTokens, label: []const u8, a11y_label: []const u8, on_click: core.HandlerRef) view.Box(StepBtnProps, view.Text(StepLabelProps, []const u8), null) {
    // subtree text is '-'/'+', fallback reads as 'hyphen'/'plus' meaningless char names; must
    // explicitly give semantic labels.
    return view.box(StepBtnProps{
        .style = stepBtnStyle(t),
        .a11y = .{ .role = .button, .label = a11y_label },
        .on_click = on_click,
    }, view.text(StepLabelProps{ .style = stepBtnLabelStyle(false, t) }, label));
}

/// create NumberStepper: `W.NumberStepper(.{ .value = qty, .min = 0 }).mount(scope, cx)`
pub fn NumberStepper(props: anytype) NumberStepperBuilder {
    return .{ .props = reactive.props.coerce(NumberStepperProps, props) };
}

pub const NumberStepperBuilder = struct {
    props: NumberStepperProps,

    pub fn mount(self: NumberStepperBuilder, scope: *Scope, cx: *Cx) !NumberStepperResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const props = self.props;
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const t = cx.tokens;
        reactive.checkBorrow(my_scope, props.disabled);
        const value = try reactive.resolveModel(f64, my_scope, props.value);
        const initially_disabled = props.disabled.read(false);

        // runtime created first (reclaimed with my_scope), button clicks point directly to it; node
        // handle filled after mount
        const rt = try my_scope.allocator.create(NumberStepperRuntime);
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NumberStepperRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        const Parts = struct { minus: *Node = undefined, value: *Node = undefined, plus: *Node = undefined };
        var parts: Parts = .{};
        const wrapper = try view.render(my_scope, cx, view.box(.{
            .style = .{ stepperWrapperStyle(props.width, t), .{ .overflow_hidden = true } },
            // role=spinbutton is ARIA's dedicated role for 'numeric input with
            // increment/decrement': AT uses this to prompt user for arrow keys, announce current
            // value and range.
            .a11y = .{ .role = .spinbutton },
        }, .{
            view.capture(&parts.minus, stepBtn(t, "-", "Decrease", .{ .callback = onMinus, .context = @ptrCast(rt) })),
            view.box(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .justify = .center,
                .align_items = .center,
            } }, view.capture(&parts.value, view.text(.{ .style = stepperValueStyle(false, t) }, "0"))),
            view.capture(&parts.plus, stepBtn(t, "+", "Increase", .{ .callback = onPlus, .context = @ptrCast(rt) })),
        }));
        wrapper.meta.ownership.meta.component_name = "NumberStepper";
        // sweep: wrapper guards until return (with disposing attached my_scope)
        errdefer cx.freeNode(wrapper);
        try core.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;

        rt.* = .{
            .value = value,
            .disabled = props.disabled,
            .on_change = props.on_change,
            .min = props.min,
            .max = props.max,
            .step = props.step,
            // NaN sentinel and negated disabled state: first view necessarily applies
            .shown = std.math.nan(f64),
            .is_disabled = !initially_disabled,
            .value_node = parts.value,
            .minus = parts.minus,
            .plus = parts.plus,
            .wrapper_node = wrapper,
            .cx = cx,
        };
        if (wrapper.behavior.interaction.a11y) |*a11y| {
            const bounded = props.min != null and props.max != null;
            a11y.value_range = .{
                .small_change = @floatCast(props.step),
                .now = 0,
                .min = @floatCast(props.min orelse 0),
                .max = @floatCast(props.max orelse 0),
                // The native value setter is only truthful when both published
                // bounds are real. Unbounded steppers remain operable through
                // increment/decrement actions instead of advertising a direct
                // setter that would be clamped to the synthetic current-value
                // fallback used for missing bounds.
                .context = if (bounded) rt else null,
                .set_value = if (bounded) setA11yStepperValue else null,
            };
        }

        // interaction always mounted, disable determined at runtime (disabled can be dynamic)
        wrapper.behavior.events.on_key_down = onStepKey;
        wrapper.behavior.events.key_context = @ptrCast(rt);

        try rt.view(false);
        // value is Model: local is also signal, interaction changes it, must have effect
        try my_scope.createEffect(rt, NumberStepperRuntime.viewEffect);
        return .{ .wrapper = wrapper, .value = value.asSignal() };
    }
};

// ============================================================================

fn runtimeOf(r: NumberStepperResult) *NumberStepperRuntime {
    return @ptrCast(@alignCast(r.wrapper.behavior.events.key_context.?));
}

fn valueText(r: NumberStepperResult) []const u8 {
    return runtimeOf(r).value_node.getText().?.content;
}

test "NumberStepper: 步进 + clamp" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try NumberStepper(.{ .value = 9, .min = 0, .max = 10, .step = 2 }).mount(scope, cx);
    try root.appendChild(testing.allocator, ns.wrapper);
    const rt = runtimeOf(ns);

    try testing.expectEqualStrings("9", valueText(ns));
    rt.increment();
    try testing.expectEqual(@as(f64, 10), ns.value.?.peek()); // clamp to max
    try testing.expectEqualStrings("10", valueText(ns));
    for (0..5) |_| rt.decrement();
    try testing.expectEqual(@as(f64, 0), ns.value.?.peek()); // clamp to min
}

test "NumberStepper: inf / 超 i64 范围的值不 panic" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try NumberStepper(.{ .value = 0, .step = 1 }).mount(scope, cx);
    try root.appendChild(testing.allocator, ns.wrapper);
    const v = ns.value.?;
    v.set(1e19);
    v.set(-0x1p63);
    v.set(std.math.inf(f64));
    v.set(-std.math.inf(f64));
    v.set(std.math.nan(f64));
    try testing.expect(valueText(ns).len > 0);
    v.set(42);
    try testing.expectEqualStrings("42", valueText(ns));
}

test "NumberStepper: bound value, landed on_change, a11y value_text follows the node copy" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const qty = try scope.createSignal(f64, 1);
    var landed: f64 = 0;
    const ns = try NumberStepper(.{ .value = qty, .min = 1, .max = 99, .on_change = cx.on(f64, &landed, struct {
        fn f(out: *f64, v: f64) void {
            out.* = v;
        }
    }.f) }).mount(scope, cx);
    defer cx.freeNode(ns.wrapper);
    qty.set(1000); // external out-of-bounds: display clamped, not written back
    try testing.expectEqualStrings("99", valueText(ns));
    try testing.expectEqual(@as(f64, 1000), qty.peek());
    cx.owner.beginBatch(); // real inputs all in host batch
    _ = onStepKey(.down, .{}, ns.wrapper.behavior.events.key_context);
    cx.owner.endBatch();
    try testing.expectEqual(@as(f64, 98), qty.peek());
    try testing.expectEqual(@as(f64, 98), landed);
    try testing.expectEqualStrings("98", valueText(ns));
    try testing.expectEqual(valueText(ns).ptr, ns.wrapper.behavior.interaction.a11y.?.value_text.?.ptr);
}

test "NumberStepper: 外部写入 NaN 后按键仍能从 min / 0 起步" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const ns = try NumberStepper(.{ .value = 3 }).mount(scope, cx);
    defer cx.freeNode(ns.wrapper);
    ns.value.?.set(std.math.nan(f64));
    runtimeOf(ns).increment();
    try testing.expectEqual(@as(f64, 1), ns.value.?.peek());
}

test "NumberStepper: on_change 在宿主 batch 内销毁组件，batch 结束时不运行已销毁的 effect" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Killer = struct {
        cx: *Cx,
        wrapper: *Node = undefined,
        fn changed(self: *@This(), _: f64) void {
            self.cx.detachChild(self.wrapper.parent.?, self.wrapper);
            self.cx.freeNode(self.wrapper);
        }
    };
    var killer = Killer{ .cx = cx };
    const ns = try NumberStepper(.{ .value = 1, .on_change = cx.on(Killer, &killer, Killer.changed) }).mount(scope, cx);
    killer.wrapper = ns.wrapper;
    try root.appendChild(testing.allocator, ns.wrapper);
    cx.owner.beginBatch();
    _ = onStepKey(.up, .{}, ns.wrapper.behavior.events.key_context);
    cx.owner.endBatch(); // view effect destroyed with scope: drain must skip it
    try testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "NumberStepper: disabled 不响应；可动态切换" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const off = try scope.createSignal(bool, true);
    const ns = try NumberStepper(.{ .value = 5, .disabled = off }).mount(scope, cx);
    try root.appendChild(testing.allocator, ns.wrapper);
    const rt = runtimeOf(ns);
    rt.increment();
    try testing.expectEqual(@as(f64, 5), ns.value.?.peek());
    try testing.expectEqual(EventResult.ignored, onStepKey(.up, .{}, ns.wrapper.behavior.events.key_context));
    try testing.expect(!ns.wrapper.behavior.interaction.focusable);
    try testing.expect(rt.plus.behavior.interaction.a11y.?.disabled);
    off.set(false);
    try testing.expect(ns.wrapper.behavior.interaction.focusable);
    try testing.expect(!rt.plus.behavior.interaction.a11y.?.disabled);
    rt.plus.behavior.events.on_click.?.callback(rt.plus.behavior.events.on_click.?.context);
    try testing.expectEqual(@as(f64, 6), ns.value.?.peek());
}

// test collection for styles.zig, this line is required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// per-allocation OOM sweep, see src/ui/components/oom_sweep.zig
test "number_stepper: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("number_stepper", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try NumberStepper(.{ .value = 9, .min = 0, .max = 10, .step = 2 }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "number_stepper: 动态值 / disabled 的 mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("number_stepper(dynamic)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const v = try scope.createSignal(f64, 3);
            const off = try scope.createSignal(bool, false);
            return (try NumberStepper(.{ .value = v, .min = 0, .max = 10, .disabled = off }).mount(scope, cx)).wrapper;
        }
    }.m);
}
