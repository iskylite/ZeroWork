//! Pure Zig reusable components (no Yix / YSS), one each of four common shapes:
//!
//!   Pill     stateless: param is `ui.Source(T)` (caller passes value or signal), style is a cva
//!   variant
//!   Stepper  controlled value: `ui.Model(T)`, self-managing if not passed, two-way bound if a
//!   signal, changes via on_change
//!   Section  with slots: children go to the component's slot (`v.with(Section(...), .{ children
//!   })`)
//!   TaskRow  multi-part recipe + event callback: `ui.Handler(void)` param wired to node click
//!
//! Matches Yix-generated code 1:1: props struct + `ui.reactive.props.coerce` (normalizes the
//! caller's anon struct, wraps plain values as static sources) + `fn (Props, *Scope, *Cx) !*Node`
//! returning `v.render(...)`. A component runs once at mount; signals then drive fine-grained
//! updates, no vdom, no re-run.
const std = @import("std");
const ui = @import("ui");
const v = ui.view;
const W = ui.widgets;
const S = @import("styles.zig");

// -- Pill: stateless component --

pub const PillProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    tone: ui.Source(S.Tone) = .{ .value = .neutral },
    /// Text in `<Pill>text</Pill>` goes into label; hand-written Zig components work as text in
    /// .yix the same way.
    pub const text_child = "label";
};

/// Capsule tag: `Pill(.{ .label = "Zig", .tone = .accent })`; tone can be signal (variant
/// switches).
pub fn Pill(args: anytype) v.ComponentOf(pill) {
    return v.component(pill, ui.reactive.props.coerce(PillProps, args));
}

fn pill(props: PillProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.row(.{ .style = S.Pill.of(.{ .tone = props.tone }) }, .{
        v.text(.{ .style = S.pill_text }, props.label),
    }));
}

// -- Stepper: controlled value --

pub const StepperProps = struct {
    /// Not passed: self-managing (init 0); signal passed: two-way bind; `ui.split(read-only,
    /// callback)`: caller decides whether to adopt.
    value: ui.Model(i32) = .{ .local = 0 },
    min: ui.Source(i32) = .{ .value = 0 },
    max: ui.Source(i32) = .{ .value = 10 },
    /// Settled new value (rejected proposals don't report).
    on_change: ?ui.Handler(i32) = null,
};

/// Stepper: `Stepper(.{ .value = level, .max = 5 })`.
pub fn Stepper(args: anytype) v.ComponentOf(stepper) {
    return v.component(stepper, ui.reactive.props.coerce(StepperProps, args));
}

fn stepper(props: StepperProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Parse controlled value into Bound: `read` is read source, `propose` proposes new value (local
    // / bound direct write, split gives caller).
    const value = try ui.reactive.resolveModelFor(i32, scope, props.value);
    const Ctx = struct { value: ui.reactive.Bound(i32), min: ui.Source(i32), max: ui.Source(i32), on_change: ?ui.Handler(i32) };
    const ctx: Ctx = .{ .value = value, .min = props.min, .max = props.max, .on_change = props.on_change };
    // Event handler: ui.on.bind copies ctx into component scope (one alloc, freed on component
    // unmount); handler uses peek to read (doesn't track deps).
    const dec = try ui.on.bind(scope, ctx, struct {
        fn run(c: Ctx) void {
            const n = c.value.read.peek();
            if (n > c.min.peek()) c.value.propose(n - 1, c.on_change);
        }
    }.run);
    const inc = try ui.on.bind(scope, ctx, struct {
        fn run(c: Ctx) void {
            const n = c.value.read.peek();
            if (n < c.max.peek()) c.value.propose(n + 1, c.on_change);
        }
    }.run);
    return v.render(scope, cx, v.row(.{ .style = S.row }, .{
        W.Button(.{ .label = "−", .variant = .secondary, .size = .sm, .on_click = dec }),
        v.text(.{ .style = S.stepper_value }, v.fmt("{d}", .{value.read})),
        W.Button(.{ .label = "+", .variant = .secondary, .size = .sm, .on_click = inc }),
    }));
}

// -- Section: with slots --

pub const SectionProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
};

/// Group: `v.with(Section(.{ .title = "Tasks" }), .{ children… })`, children into title's content
/// below.
pub fn Section(args: anytype) v.SlottedOf(section) {
    return v.slotted(section, ui.reactive.props.coerce(SectionProps, args));
}

fn section(props: SectionProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!v.ViewParts {
    // slotEnd marks slot position (this col's end); slottedParts gives root and slot to framework,
    // caller's children hook there.
    var body: ?v.SlotPoint = null;
    const root = try v.render(scope, cx, v.col(.{ .style = S.section }, .{
        v.text(.{ .style = S.section_title }, props.title),
        v.slotEnd(&body, v.col(.{ .style = S.section_body }, .{})),
    }));
    return v.slottedParts(root, body, .{});
}

// -- TaskRow: multi-part recipe + event callback --

pub const TaskRowProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    done: ui.Source(bool) = .{ .value = false },
    on_toggle: ?ui.Handler(void) = null,
    on_remove: ?ui.Handler(void) = null,
};

/// Task row: checkbox + title + remove button; done can be source (parts' styles toggle).
pub fn TaskRow(args: anytype) v.ComponentOf(taskRow) {
    return v.component(taskRow, ui.reactive.props.coerce(TaskRowProps, args));
}

fn taskRow(props: TaskRowProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Multi-part recipe: one variant value drives all parts (slot(.name, variant_value) is regular
    // style component).
    const done = .{ .done = props.done };
    return v.render(scope, cx, v.row(.{ .style = S.TaskRow.slot(.root, done) }, .{
        v.box(.{ .style = S.TaskRow.slot(.check, done), .on_click = props.on_toggle, .a11y = .{ .role = .checkbox, .label = "Done" } }, .{}),
        v.text(.{ .style = S.TaskRow.slot(.title, done) }, props.title),
        v.spacer(),
        W.Button(.{ .label = "Remove", .variant = .ghost, .size = .sm, .on_click = props.on_remove }),
    }));
}
